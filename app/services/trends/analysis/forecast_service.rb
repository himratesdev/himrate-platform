# frozen_string_literal: true

# TASK-039 FR-026: Linear forecast для TI/ERV series с ±2σ confidence bands.
# Feeds /trends/erv + /trends/trust-index (dashed projection line в M1/M2).
#
# Horizon: 7d + 30d (configurable via SignalConfiguration.trends.forecast.horizon_days_*).
# Reliability classification: R² high/medium/low (thresholds в DB).
#   - low R² → UI blur + disclaimer (FR-026 spec).
#   - <min_points → возвращает nil (UI hides forecast block).
#
# Math: uses shared LinearRegression.fit. Confidence band = residual_std × z
# (z=1.96 ≈ 95% CI, z=2.576 ≈ 99%). Default z=1.96 per SRS §4.1 (±2σ-ish, 95%).

module Trends
  module Analysis
    class ForecastService
      Z_95 = 1.96

      def self.call(points)
        new(points).call
      end

      def initialize(points)
        @points = points
      end

      def call
        min_points = SignalConfiguration.value_for("trends", "forecast", "min_points_for_forecast").to_i
        return nil if @points.size < min_points

        fit = Trends::Analysis::Math::LinearRegression.fit(@points)
        return nil if fit.nil?

        horizon_short = SignalConfiguration.value_for("trends", "forecast", "horizon_days_short").to_i
        horizon_long = SignalConfiguration.value_for("trends", "forecast", "horizon_days_long").to_i
        r2_high = SignalConfiguration.value_for("trends", "forecast", "reliability_high_r2").to_f
        r2_medium = SignalConfiguration.value_for("trends", "forecast", "reliability_medium_r2").to_f

        last_x = @points.last[0].to_f

        {
          forecast_7d: clamp_band(fit.confidence_band(last_x + horizon_short, Z_95)),
          forecast_30d: clamp_band(fit.confidence_band(last_x + horizon_long, Z_95)),
          reliability: classify_reliability(fit.r_squared, r2_high, r2_medium),
          r_squared: fit.r_squared,
          slope_per_day: fit.slope.round(4)
        }
      end

      private

      # Clamp value/lower/upper to [0, 100] — TI/ERV domain. Preserves round(2) precision.
      def clamp_band(band)
        {
          value: band[:value].clamp(0.0, 100.0).round(2),
          lower: band[:lower].clamp(0.0, 100.0).round(2),
          upper: band[:upper].clamp(0.0, 100.0).round(2)
        }
      end

      def classify_reliability(r_squared, high, medium)
        return "high" if r_squared >= high
        return "medium" if r_squared >= medium

        "low"
      end
    end
  end
end
