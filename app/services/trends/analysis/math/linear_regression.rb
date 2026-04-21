# frozen_string_literal: true

# TASK-039 Phase B3: Shared OLS linear regression helper.
# Used by TrendCalculator (FR-024), ForecastService (FR-026),
# DiscoveryPhaseDetector (FR-029) for linear vs step comparison.
#
# Returns nil if ≤1 distinct x (no regression possible) or zero variance.
# Build-for-years: pure math, zero DB coupling, reusable.

module Trends
  module Analysis
    module Math
      class LinearRegression
        Result = Data.define(:intercept, :slope, :r_squared, :residual_std, :n) do
          def predict(x) = intercept + slope * x
          def confidence_band(x, z = 1.96)
            half = z * residual_std
            { value: predict(x).round(4), lower: (predict(x) - half).round(4), upper: (predict(x) + half).round(4) }
          end
        end

        # points: Array of [x Numeric, y Numeric]. Returns Result or nil.
        def self.fit(points)
          points = points.reject { |x, y| x.nil? || y.nil? }
          return nil if points.size < 2

          xs = points.map { |p| p[0].to_f }
          ys = points.map { |p| p[1].to_f }
          n = points.size

          x_mean = xs.sum / n
          y_mean = ys.sum / n

          xx = 0.0
          xy = 0.0
          yy = 0.0
          xs.each_with_index do |x, i|
            dx = x - x_mean
            dy = ys[i] - y_mean
            xx += dx * dx
            xy += dx * dy
            yy += dy * dy
          end

          return nil if xx.zero?

          slope = xy / xx
          intercept = y_mean - slope * x_mean

          # Residual sum of squares from OLS fit
          ss_res = 0.0
          xs.each_with_index do |x, i|
            predicted = intercept + slope * x
            ss_res += (ys[i] - predicted)**2
          end

          # R² = 1 - SS_res/SS_tot. If yy == 0, data is constant → undefined; return 1.0
          # only when residuals are also 0 (perfect flat fit). Otherwise 0 signals poor fit.
          r_squared =
            if yy.zero?
              ss_res.zero? ? 1.0 : 0.0
            else
              [ 0.0, 1.0 - ss_res / yy ].max
            end

          # Sample residual std (n-2 degrees of freedom). For n==2, exact fit → 0.
          residual_std = n > 2 ? ::Math.sqrt(ss_res / (n - 2)) : 0.0

          Result.new(
            intercept: intercept,
            slope: slope,
            r_squared: r_squared.round(4),
            residual_std: residual_std.round(4),
            n: n
          )
        end

        # Pearson correlation coefficient for (x, y) pairs.
        # Returns Float in [-1, 1] or nil if zero variance in either series.
        def self.pearson_r(pairs)
          pairs = pairs.reject { |x, y| x.nil? || y.nil? }
          return nil if pairs.size < 2

          xs = pairs.map { |p| p[0].to_f }
          ys = pairs.map { |p| p[1].to_f }
          n = pairs.size

          x_mean = xs.sum / n
          y_mean = ys.sum / n

          num = 0.0
          x_var = 0.0
          y_var = 0.0
          xs.each_with_index do |x, i|
            dx = x - x_mean
            dy = ys[i] - y_mean
            num += dx * dy
            x_var += dx * dx
            y_var += dy * dy
          end

          return nil if x_var.zero? || y_var.zero?

          (num / ::Math.sqrt(x_var * y_var)).clamp(-1.0, 1.0).round(4)
        end
      end
    end
  end
end
