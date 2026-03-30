# frozen_string_literal: true

# TASK-028 FR-004: CCV Tier Clustering signal.
# CCV stabilizes around commercial bot tiers (100, 500, 1K, 5K, 10K).
# Adaptive CV threshold: base_threshold × sqrt(reference_ccv / mean_ccv).

module TrustIndex
  module Signals
    class CcvTierClustering < BaseSignal
      MIN_SNAPSHOTS = 15
      KNOWN_TIERS = [ 100, 500, 1_000, 5_000, 10_000 ].freeze
      BASE_THRESHOLD = 0.05
      REFERENCE_CCV = 200.0
      TIER_PROXIMITY_THRESHOLD = 0.95

      def name = "CCV Tier Clustering"
      def signal_type = "ccv_tier_clustering"

      def calculate(context)
        ccv_series = context[:ccv_series_30min] || []

        return insufficient(reason: "insufficient_data") if ccv_series.size < MIN_SNAPSHOTS

        values = ccv_series.map { |s| s[:ccv].to_f }
        mean_ccv = values.sum / values.size
        return insufficient(reason: "mean_zero") if mean_ccv.zero?

        std_ccv = Math.sqrt(values.sum { |v| (v - mean_ccv)**2 } / values.size)
        cv = std_ccv / mean_ccv

        # Adaptive threshold per BFT §5.4
        adaptive_threshold = BASE_THRESHOLD * Math.sqrt(REFERENCE_CCV / mean_ccv)

        cv_signal = if cv < adaptive_threshold
                      (1.0 - cv / adaptive_threshold).clamp(0.0, 1.0)
        else
                      0.0
        end

        # Tier proximity check
        tier_signal = compute_tier_proximity(mean_ccv)

        value = [ cv_signal, tier_signal * 0.8 ].max
        confidence = [ 1.0, ccv_series.size / 30.0 ].min

        result(
          value: value,
          confidence: confidence,
          metadata: {
            mean_ccv: mean_ccv.round(1), cv: cv.round(4),
            adaptive_threshold: adaptive_threshold.round(4),
            cv_signal: cv_signal.round(4), tier_signal: tier_signal.round(4),
            nearest_tier: nearest_tier(mean_ccv), snapshots: ccv_series.size
          }
        )
      end

      private

      def compute_tier_proximity(mean_ccv)
        KNOWN_TIERS.map do |tier|
          proximity = 1.0 - (mean_ccv - tier).abs / tier.to_f
          proximity > TIER_PROXIMITY_THRESHOLD ? proximity : 0.0
        end.max
      end

      def nearest_tier(mean_ccv)
        KNOWN_TIERS.min_by { |t| (mean_ccv - t).abs }
      end
    end
  end
end
