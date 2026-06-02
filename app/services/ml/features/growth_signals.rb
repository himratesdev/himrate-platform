# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR5 — Growth signals (4 features) per BFT 15_ML-Pipeline.md §3.2.
#
# Data source: `FollowerSnapshot` (channel-level daily snapshot from `FollowerSnapshotWorker`)
# + `Stream` (channel lifetime) for attribution attribution. RaidAttribution lives inside
# Stream — `belongs_to :stream` — so stream-presence in the window implicitly covers the raid
# case. Conversely a spike on a day without ANY stream is unattributed (no organic surface
# to credit the followers to — characteristic of purchased growth).
#
# Window: 90 days (matches `FollowerSnapshotWorker` retention assumption and `WINDOW = 90.days`
# convention from BFT §3.2 Growth). Per-feature cold-start: returns nil if source data
# insufficient, records reason in `insufficient_data_reasons` for observability.
#
# Math choices:
# - `follower_growth_cv_90d` = std/|mean| of daily deltas — captures volatility independent
#   of growth direction. Sign-agnostic (|mean|) so a declining channel still has finite CV.
# - `growth_engagement_correlation` = Pearson(daily_delta, daily_stream_count_in_window) —
#   measures whether growth coincides with on-air activity. Low/negative corr = follower
#   growth decoupled from streaming = suspicious pattern.
# - `follow_unfollow_churn_rate` = fraction of negative-delta days — proxy for churn. Healthy
#   channels mostly net-positive; high churn rate = volatile audience or unfollow campaigns.
# - `attributed_spike_ratio` = fraction of spike days (delta > μ+2σ) that have ≥1 active stream
#   in the snapshot interval. Spike WITHOUT streaming activity = unattributed (likely paid).
module Ml
  module Features
    class GrowthSignals
      WINDOW = 90.days
      MIN_SNAPSHOTS_FOR_CV = 7              # ≥7 daily points for variance stability
      MIN_SNAPSHOTS_FOR_CORRELATION = 14    # Pearson needs ~2 weeks for stable estimate
      SPIKE_THRESHOLD_SIGMA = 2.0           # delta > μ + 2σ = spike day

      def initialize(stream)
        @stream = stream
      end

      def call
        {
          follower_growth_cv_90d:        follower_growth_cv_90d,
          growth_engagement_correlation: growth_engagement_correlation,
          follow_unfollow_churn_rate:    follow_unfollow_churn_rate,
          attributed_spike_ratio:        attributed_spike_ratio
        }
      end

      def insufficient_data_reasons
        @insufficient_data_reasons ||= {}
      end

      private

      # Ordered (timestamp, count) tuples over the 90d window.
      def follower_snapshots
        @follower_snapshots ||= FollowerSnapshot
          .where(channel_id: @stream.channel_id)
          .where("timestamp >= ?", WINDOW.ago)
          .order(:timestamp)
          .pluck(:timestamp, :followers_count)
      end

      # Consecutive deltas. size = follower_snapshots.size - 1.
      def daily_deltas
        @daily_deltas ||= follower_snapshots.each_cons(2).map { |(_, c0), (_, c1)| c1 - c0 }
      end

      # All stream starts in the 90d window — used for attributed_spike_ratio AND
      # growth_engagement_correlation. Pluck once; both consumers iterate the array.
      def stream_starts
        @stream_starts ||= Stream
          .for_channel(@stream.channel_id)
          .where("started_at >= ?", WINDOW.ago)
          .pluck(:started_at)
      end

      def follower_growth_cv_90d
        if daily_deltas.size < MIN_SNAPSHOTS_FOR_CV
          insufficient_data_reasons[:follower_growth_cv_90d] = "insufficient_snapshots"
          return nil
        end
        mean = daily_deltas.sum.to_f / daily_deltas.size
        if mean.abs < 1e-6
          # All-zero series or perfectly balanced churn — CV undefined.
          insufficient_data_reasons[:follower_growth_cv_90d] = "zero_mean_growth"
          return nil
        end
        variance = daily_deltas.sum { |d| (d - mean)**2 } / daily_deltas.size
        (Math.sqrt(variance) / mean.abs).round(4)
      end

      def growth_engagement_correlation
        if daily_deltas.size < MIN_SNAPSHOTS_FOR_CORRELATION
          insufficient_data_reasons[:growth_engagement_correlation] = "insufficient_snapshots"
          return nil
        end
        # Pair each delta with the count of streams that started in [t0, t1).
        engagement = follower_snapshots.each_cons(2).map { |(t0, _), (t1, _)|
          stream_starts.count { |s| s >= t0 && s < t1 }
        }
        result = pearson(daily_deltas.map(&:to_f), engagement.map(&:to_f))
        if result.nil?
          insufficient_data_reasons[:growth_engagement_correlation] = "zero_variance_series"
        end
        result
      end

      def follow_unfollow_churn_rate
        if daily_deltas.size < MIN_SNAPSHOTS_FOR_CV
          insufficient_data_reasons[:follow_unfollow_churn_rate] = "insufficient_snapshots"
          return nil
        end
        # Fraction of intervals with net unfollow (negative delta).
        (daily_deltas.count(&:negative?).to_f / daily_deltas.size).round(4)
      end

      def attributed_spike_ratio
        if daily_deltas.size < MIN_SNAPSHOTS_FOR_CV
          insufficient_data_reasons[:attributed_spike_ratio] = "insufficient_snapshots"
          return nil
        end
        mean = daily_deltas.sum.to_f / daily_deltas.size
        variance = daily_deltas.sum { |d| (d - mean)**2 } / daily_deltas.size
        std = Math.sqrt(variance)
        threshold = mean + SPIKE_THRESHOLD_SIGMA * std

        # Collect spike intervals as (t0, t1) bounds — keep both bounds for stream attribution.
        spike_intervals = follower_snapshots.each_cons(2).with_index.filter_map { |((t0, _), (t1, _)), i|
          [ t0, t1 ] if daily_deltas[i] > threshold
        }

        if spike_intervals.empty?
          # No spike days at all — feature undefined for this channel. nil + reason
          # is more honest than 0.0 (which would imply "all spikes unattributed").
          insufficient_data_reasons[:attributed_spike_ratio] = "no_spike_days"
          return nil
        end

        attributed = spike_intervals.count { |(t0, t1)|
          stream_starts.any? { |s| s >= t0 && s < t1 }
        }
        (attributed.to_f / spike_intervals.size).round(4)
      end

      # Pearson correlation. Returns nil if either series has zero variance (degenerate denom).
      def pearson(xs, ys)
        return nil if xs.size != ys.size || xs.size < 2
        n = xs.size.to_f
        mean_x = xs.sum / n
        mean_y = ys.sum / n
        cov = xs.zip(ys).sum { |x, y| (x - mean_x) * (y - mean_y) }
        var_x = xs.sum { |x| (x - mean_x)**2 }
        var_y = ys.sum { |y| (y - mean_y)**2 }
        denom = Math.sqrt(var_x * var_y)
        return nil if denom.zero?
        (cov / denom).round(4)
      end
    end
  end
end
