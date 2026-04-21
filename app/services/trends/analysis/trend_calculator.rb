# frozen_string_literal: true

# TASK-039 FR-024: Computes trend direction + slope + R² confidence for a metric
# series (TI or ERV). Consumed by /trends/erv + /trends/trust-index endpoints
# и ExplanationBuilder (FR-025, narrative generation).
#
# Input: points as [[x Numeric, y Numeric], ...] — x typically day-offset from period start.
# Output: {direction, delta, slope_per_day, r_squared, confidence, start_value, end_value}.
#
# Thresholds в SignalConfiguration (trends/trend/*): build-for-years.
# Returns nil-shape when <2 points (no trend computable).

module Trends
  module Analysis
    class TrendCalculator
      def self.call(points)
        new(points).call
      end

      def initialize(points)
        @points = points
      end

      def call
        return empty_result if @points.size < 2

        fit = Trends::Analysis::Math::LinearRegression.fit(@points)
        return empty_result if fit.nil?

        rising_min = SignalConfiguration.value_for("trends", "trend", "direction_rising_slope_min").to_f
        declining_max = SignalConfiguration.value_for("trends", "trend", "direction_declining_slope_max").to_f
        conf_high = SignalConfiguration.value_for("trends", "trend", "confidence_high_r2").to_f
        conf_medium = SignalConfiguration.value_for("trends", "trend", "confidence_medium_r2").to_f

        slope = fit.slope.round(4)
        direction = classify_direction(slope, rising_min, declining_max)
        confidence = classify_confidence(fit.r_squared, conf_high, conf_medium)

        first_y = @points.first[1].to_f
        last_y = @points.last[1].to_f

        {
          direction: direction,
          slope_per_day: slope,
          delta: (last_y - first_y).round(2),
          r_squared: fit.r_squared,
          confidence: confidence,
          start_value: first_y.round(2),
          end_value: last_y.round(2),
          n_points: fit.n
        }
      end

      private

      def classify_direction(slope, rising_min, declining_max)
        return "rising" if slope >= rising_min
        return "declining" if slope <= declining_max

        "flat"
      end

      def classify_confidence(r_squared, high, medium)
        return "high" if r_squared >= high
        return "medium" if r_squared >= medium

        "low"
      end

      def empty_result
        {
          direction: nil,
          slope_per_day: nil,
          delta: nil,
          r_squared: nil,
          confidence: nil,
          start_value: nil,
          end_value: nil,
          n_points: @points.size
        }
      end
    end
  end
end
