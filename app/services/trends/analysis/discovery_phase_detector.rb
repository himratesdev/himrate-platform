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

        burst = detect_burst(series, cfg)
        return result("anomalous_burst", burst[:score], "Rapid follower jump detected", cfg.merge(burst)) if burst[:classified]

        organic = fit_logistic(series, cfg)
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

      # Burst = any window ≤ burst_window_days в котором delta ≥ burst_jump_min.
      # Simple step-detection: peek rolling deltas.
      def detect_burst(series, cfg)
        return { classified: false, score: 0.0 } if series.size < cfg[:burst_window] + 1

        max_jump = 0.0
        max_jump_start = nil
        (0..series.size - cfg[:burst_window] - 1).each do |i|
          delta = series[i + cfg[:burst_window]][1] - series[i][1]
          if delta > max_jump
            max_jump = delta
            max_jump_start = i
          end
        end

        classified = max_jump >= cfg[:burst_jump]
        score = max_jump / (cfg[:burst_jump] * 2.0) # normalized 0..1 (capped)

        {
          classified: classified,
          score: score.clamp(0.0, 1.0).round(3),
          jump_size: max_jump.round(0),
          jump_window_start_idx: max_jump_start
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
