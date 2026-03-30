# frozen_string_literal: true

# TASK-028 FR-003: CCV Step Function signal.
# z-score > 3.0 + Kolmogorov-Smirnov test.
# Detects anomalous CCV jumps (bot injection).

module TrustIndex
  module Signals
    class CcvStepFunction < BaseSignal
      MIN_SNAPSHOTS = 5

      def name = "CCV Step Function"
      def signal_type = "ccv_step_function"

      def calculate(context)
        ccv_series = context[:ccv_series_15min] || []
        recent_raids = context[:recent_raids] || []

        return insufficient(reason: "insufficient_data") if ccv_series.size < MIN_SNAPSHOTS

        z_signal = compute_z_score(ccv_series)
        ks_signal = compute_ks_test(ccv_series)

        combined = [ z_signal, ks_signal ].max

        # Raid dampening: if raid in last 5min, reduce signal (spike explained by raid)
        combined *= 0.2 if recent_raids.any?

        confidence = [ 1.0, ccv_series.size / 15.0 ].min

        result(
          value: combined,
          confidence: confidence,
          metadata: { z_signal: z_signal.round(4), ks_signal: ks_signal.round(4), raid_dampened: recent_raids.any?, snapshots: ccv_series.size }
        )
      end

      private

      def compute_z_score(series)
        values = series.map { |s| s[:ccv] }
        deltas = values.each_cons(2).map { |a, b| b - a }
        return 0.0 if deltas.size < 2

        mean = deltas.sum.to_f / deltas.size
        variance = deltas.sum { |d| (d - mean)**2 } / deltas.size
        std = Math.sqrt(variance)
        return 0.0 if std.zero?

        latest_delta = deltas.last
        z_score = (latest_delta - mean).abs / std

        # Normalize: z=3 → 0.5, z=6 → 1.0
        (z_score / 6.0).clamp(0.0, 1.0)
      end

      # Kolmogorov-Smirnov test: compare recent window vs historical.
      # Two-sample KS statistic: max |F1(x) - F2(x)|.
      # Significant if D > critical value (approximation for small samples).
      def compute_ks_test(series)
        values = series.map { |s| s[:ccv] }
        return 0.0 if values.size < 8

        # Split: last 1/3 vs first 2/3
        split = (values.size * 2 / 3).clamp(3, values.size - 3)
        historical = values[0...split].sort
        recent = values[split..].sort

        d_stat = ks_statistic(historical, recent)
        n1 = historical.size.to_f
        n2 = recent.size.to_f

        # Critical value approximation (α=0.001): c(α) ≈ 1.95
        critical = 1.95 * Math.sqrt((n1 + n2) / (n1 * n2))

        if d_stat > critical
          # p-value approximation: significant change detected
          # Scale: D just above critical → 0.5, D >> critical → 1.0
          ((d_stat - critical) / critical + 0.5).clamp(0.5, 1.0)
        else
          0.0
        end
      end

      def ks_statistic(sample1, sample2)
        all_values = (sample1 + sample2).uniq.sort
        max_d = 0.0

        all_values.each do |x|
          f1 = sample1.count { |v| v <= x } / sample1.size.to_f
          f2 = sample2.count { |v| v <= x } / sample2.size.to_f
          d = (f1 - f2).abs
          max_d = d if d > max_d
        end

        max_d
      end
    end
  end
end
