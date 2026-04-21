# frozen_string_literal: true

# TASK-039 FR-029: Detect discovery-phase type for new channel (<60d old).
# Classifications:
#   - organic          : logistic S-curve fit R² ≥ organic_threshold (healthy ramp)
#   - anomalous_burst  : step jump within ≤ burst_window_days (≥ burst_jump_min)
#   - missing          : flat / no growth (stagnant discovery)
#   - not_applicable   : channel > max_channel_age_days (not new)
#   - insufficient_data: < min_data_points follower snapshots
#
# Source: follower_snapshots (channel-level, aggregated to daily max).
# Score persisted в trends_daily_aggregates.discovery_phase_score (computed once
# at day=stable_phase_start_day per SRS §FR-029; refreshed on each aggregation run).
#
# Thresholds в SignalConfiguration.trends.discovery.*. Build-for-years: admin-tunable.

module Trends
  module Analysis
    class DiscoveryPhaseDetector
      def self.call(channel)
        new(channel).call
      end

      def initialize(channel)
        @channel = channel
      end

      def call
        cfg = load_config
        return result("not_applicable", nil, "Channel age exceeds discovery window", nil) if channel_age_days > cfg[:max_age]

        series = follower_daily_series
        return result("insufficient_data", nil, "Too few follower snapshots", cfg) if series.size < cfg[:min_points]

        # CR M-1: fit BOTH step function and logistic curve, pick best by R².
        # Step-function classification requires (a) strong step R² ≥ burst_r2 cfg
        # AND (b) rapid jump (within burst_window_days) AND (c) minimum jump_size.
        # Raw jump_size alone is insufficient — SRS §2.10 FR-029 explicitly
        # specifies R²-based model comparison.
        step = fit_step(series, cfg)
        organic = fit_logistic(series, cfg)

        if step[:classified] && step[:r_squared] >= organic[:r_squared]
          return result("anomalous_burst", step[:r_squared], "Rapid follower jump detected", cfg.merge(step))
        end

        return result("organic", organic[:r_squared], "Smooth growth curve", cfg.merge(organic)) if organic[:r_squared] >= cfg[:organic_r2]

        result("missing", organic[:r_squared], "No clear growth pattern", cfg.merge(organic))
      end

      private

      def load_config
        {
          max_age: SignalConfiguration.value_for("trends", "discovery", "channel_age_max_days").to_i,
          min_points: SignalConfiguration.value_for("trends", "discovery", "min_data_points").to_i,
          organic_r2: SignalConfiguration.value_for("trends", "discovery", "logistic_r2_organic_min").to_f,
          burst_r2: SignalConfiguration.value_for("trends", "discovery", "step_r2_burst_min").to_f,
          burst_window: SignalConfiguration.value_for("trends", "discovery", "burst_window_days_max").to_i,
          burst_jump: SignalConfiguration.value_for("trends", "discovery", "burst_jump_min").to_f
        }
      end

      def channel_age_days
        return Float::INFINITY unless @channel.created_at

        ((Time.current - @channel.created_at) / 1.day).to_i
      end

      # Daily max followers_count (latest snapshot per day).
      def follower_daily_series
        FollowerSnapshot
          .where(channel_id: @channel.id)
          .pluck(Arel.sql("DATE(timestamp)"), :followers_count)
          .group_by(&:first)
          .transform_values { |rows| rows.map { |_, v| v.to_i }.max }
          .sort_by(&:first)
          .map.with_index { |(_, val), idx| [ idx.to_f, val.to_f ] }
      end

      # CR M-1: Step function (Heaviside) fit с R². Tries each interior split point
      # as t0, computes piecewise-constant model f(t) = a for t<t0, b for t≥t0.
      # Best R² determines anomalous_burst classification per SRS §2.10 FR-029:
      #   - R² ≥ step_r2_burst_min (config)
      #   - AND burst_window ≤ burst_window_days_max (rapid jump, not gradual shift)
      #   - AND jump_size ≥ burst_jump_min (minimum magnitude threshold)
      def fit_step(series, cfg)
        return { classified: false, r_squared: 0.0 } if series.size < 3

        ys = series.map { |_, y| y.to_f }
        mean = ys.sum / ys.size
        ss_tot = ys.sum { |y| (y - mean)**2 }

        # All-equal sequence → degenerate (no meaningful step). Return 0 R².
        return { classified: false, r_squared: 0.0 } if ss_tot.zero?

        best = { r_squared: 0.0, split_idx: nil, jump_size: 0.0 }

        (1...series.size).each do |split|
          left = ys[0...split]
          right = ys[split..]
          left_mean = left.sum / left.size
          right_mean = right.sum / right.size
          ss_res = left.sum { |y| (y - left_mean)**2 } + right.sum { |y| (y - right_mean)**2 }
          r2 = 1.0 - ss_res / ss_tot

          if r2 > best[:r_squared]
            best = {
              r_squared: r2,
              split_idx: split,
              jump_size: (right_mean - left_mean).round(0),
              window_days: series[split][0] - series[split - 1][0]
            }
          end
        end

        classified = best[:r_squared] >= cfg[:burst_r2] &&
                     best[:jump_size].abs >= cfg[:burst_jump] &&
                     (best[:window_days] || 0) <= cfg[:burst_window]

        {
          classified: classified,
          r_squared: best[:r_squared].clamp(0.0, 1.0).round(4),
          jump_size: best[:jump_size],
          split_idx: best[:split_idx],
          window_days: best[:window_days]
        }
      end

      # Logistic fit approximated via linearization y' = log(y / (L - y)) vs t.
      # L estimated as max(followers) × 1.1 (carrying capacity with headroom).
      # Points where y>=L are clipped. Fallback to linear regression R² if logistic degenerate.
      def fit_logistic(series, _cfg)
        max_y = series.map { |_, v| v }.max.to_f
        return { r_squared: 0.0 } if max_y.zero?

        capacity = max_y * 1.1
        linearized = series.filter_map do |t, y|
          eps = 1e-6
          ratio = (y / (capacity - y)).clamp(eps, 1 / eps)
          [ t, ::Math.log(ratio) ]
        end

        fit = Trends::Analysis::Math::LinearRegression.fit(linearized)
        return { r_squared: 0.0 } if fit.nil?

        {
          r_squared: fit.r_squared,
          slope: fit.slope.round(4),
          capacity: capacity.round(0)
        }
      end

      def result(status, score, details_en, ctx)
        {
          status: status,
          score: score&.to_f&.round(3),
          details_en: details_en,
          details_ru: details_en, # ExplanationBuilder can enrich via i18n lookup later
          context: ctx || {}
        }
      end
    end
  end
end
