# frozen_string_literal: true

# EPIC ML-FEATURE-EXTRACTOR PR2 — Viewer signals (4 features) per BFT 15_ML-Pipeline.md §3.2.
#
# Data sources:
# - CcvSnapshot (per-minute ccv polling per stream — TASK-025)
# - ChattersSnapshot (per-minute auth chatter count per stream — TASK-025)
# - Stream.avg_ccv / Stream.peak_ccv (pre-computed during stream lifecycle)
# - For longitudinal "30-stream CV" — channel.streams (last 30 completed)
#
# Per-feature cold-start: returns nil if source data insufficient. LightGBM trees handle
# NULL natively via missing-value splits.
module Ml
  module Features
    class ViewerSignals
      # CR-247 N3-style: 3-snapshot minimum for in-stream variance features (peak/avg ratios,
      # CV). Below that, any divergence-based metric is noise. The 30-stream threshold for
      # the longitudinal CV is BFT-prescribed (15_ML-Pipeline §3.2).
      MIN_IN_STREAM_SNAPSHOTS = 3
      LONGITUDINAL_STREAMS_WINDOW = 30

      # BFT 15_ML-Pipeline §3.2 — commercial bot package tiers. Sources from typical
      # CCV-bot service pricing pages (200/500/1000/1500 = common "starter/silver/gold/platinum"
      # SKUs). Distinct from existing `ccv_tier_clustering` TI signal which uses
      # 100/500/1K/5K/10K — different historical calibration.
      BOT_TIERS = [ 200, 500, 1000, 1500 ].freeze

      def initialize(stream)
        @stream = stream
      end

      # Returns Hash with 4 viewer feature keys, each value numeric or nil (insufficient data).
      def call
        ccv_values = ccv_snapshot_values
        {
          chatter_to_ccv_ratio: chatter_to_ccv_ratio(ccv_values),
          peak_to_average_ccv_ratio: peak_to_average_ccv_ratio(ccv_values),
          ccv_coefficient_of_variation: ccv_coefficient_of_variation,
          ccv_tier_stickiness: ccv_tier_stickiness(ccv_values)
        }
      end

      # Returns insufficient_data reasons for any features that returned nil.
      # Populated for observability — extractor_metadata.insufficient_data_reasons.viewer.
      def insufficient_data_reasons
        @insufficient_data_reasons ||= {}
      end

      private

      def ccv_snapshot_values
        @ccv_snapshot_values ||= @stream.ccv_snapshots.pluck(:ccv_count).map(&:to_f)
      end

      def chatter_snapshot_values
        @chatter_snapshot_values ||= @stream.chatters_snapshots.pluck(:unique_chatters_count).map(&:to_f)
      end

      # chatter_to_ccv_ratio: mean(unique_chatters) / mean(ccv). Real engagement metric —
      # bot CCV inflates denominator without chatter participation. Per-stream feature.
      def chatter_to_ccv_ratio(ccv_values)
        chatters = chatter_snapshot_values
        return record_insufficient(:chatter_to_ccv_ratio, "no_ccv_snapshots") if ccv_values.empty?
        return record_insufficient(:chatter_to_ccv_ratio, "no_chatter_snapshots") if chatters.empty?

        mean_ccv = ccv_values.sum / ccv_values.size
        return record_insufficient(:chatter_to_ccv_ratio, "zero_mean_ccv") if mean_ccv.zero?

        mean_chatters = chatters.sum / chatters.size
        (mean_chatters / mean_ccv).round(4)
      end

      # peak_to_average_ccv_ratio: max(ccv) / mean(ccv). Spike-detection within stream —
      # high ratio = brief bot burst. Per-stream feature.
      def peak_to_average_ccv_ratio(ccv_values)
        return record_insufficient(:peak_to_average_ccv_ratio, "insufficient_snapshots") if ccv_values.size < MIN_IN_STREAM_SNAPSHOTS

        mean_ccv = ccv_values.sum / ccv_values.size
        return record_insufficient(:peak_to_average_ccv_ratio, "zero_mean_ccv") if mean_ccv.zero?

        peak_ccv = ccv_values.max
        (peak_ccv / mean_ccv).round(4)
      end

      # ccv_coefficient_of_variation: BFT spec "(30 streams)" — std/mean of avg_ccv across
      # the last 30 completed streams of this channel. Low CV = suspicious stability
      # (real audience varies; bot packages produce consistent CCV). Channel-level
      # longitudinal stat persisted with each stream's row.
      def ccv_coefficient_of_variation
        # Include the current stream if ended; otherwise fall back to last 30 *prior* completed.
        recent = @stream.channel
                        .streams
                        .where.not(ended_at: nil)
                        .order(ended_at: :desc)
                        .limit(LONGITUDINAL_STREAMS_WINDOW)
                        .pluck(:avg_ccv)
                        .compact
                        .map(&:to_f)

        return record_insufficient(:ccv_coefficient_of_variation, "insufficient_history") if recent.size < MIN_IN_STREAM_SNAPSHOTS

        mean = recent.sum / recent.size
        return record_insufficient(:ccv_coefficient_of_variation, "zero_historical_mean") if mean.zero?

        variance = recent.sum { |v| (v - mean)**2 } / recent.size
        std = Math.sqrt(variance)
        (std / mean).round(4)
      end

      # ccv_tier_stickiness: how close the stream's mean CCV sits to the nearest commercial
      # bot package tier (200/500/1000/1500). 1.0 = mean equals a tier, 0.0 = far from any.
      # Per BFT 15_ML-Pipeline §3.2.
      def ccv_tier_stickiness(ccv_values)
        return record_insufficient(:ccv_tier_stickiness, "insufficient_snapshots") if ccv_values.size < MIN_IN_STREAM_SNAPSHOTS

        mean = ccv_values.sum / ccv_values.size
        return record_insufficient(:ccv_tier_stickiness, "zero_mean_ccv") if mean.zero?

        nearest_tier = BOT_TIERS.min_by { |t| (mean - t).abs }
        # Normalised distance within ±50% of the nearest tier — beyond that we treat the
        # stream as "not in any tier neighbourhood" (proximity = 0). Within neighbourhood
        # proximity = 1 - (dist / tier_half_band).
        tier_half_band = nearest_tier * 0.5
        dist = (mean - nearest_tier).abs
        return 0.0 if dist >= tier_half_band

        (1.0 - dist / tier_half_band).round(4)
      end

      # Helper: record an insufficient_data reason for observability, return nil.
      def record_insufficient(feature_key, reason)
        insufficient_data_reasons[feature_key] = reason
        nil
      end
    end
  end
end
