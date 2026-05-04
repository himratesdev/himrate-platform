# frozen_string_literal: true

# TASK-085 FR-015: ERV Divergence Detector — extends signal_compute_worker chain.
# Reads ErvEstimate stream-scoped за 15min window. Triggers anomaly при ratio Δ > 10%.
# Severity computed в presenter (yellow Δ ≥ 10%, red ≥ 20% per BR-011).
#
# Reuses AnomalyAlerter dedup pattern (5min window per stream + anomaly_type) per FR-016.

module TrustIndex
  module Signals
    class ErvDivergenceDetector
      WINDOW = 15.minutes
      DELTA_THRESHOLD_PCT = 10.0
      DEDUP_WINDOW = 5.minutes

      # Check ErvEstimate для divergence > 10%. Returns array of created anomaly IDs.
      def self.check(stream)
        estimates = ErvEstimate
          .where(stream: stream)
          .where("timestamp > ?", WINDOW.ago)
          .order(:timestamp)
          .pluck(:erv_percent)

        return [] if estimates.size < 2

        baseline = estimates.first.to_f
        latest = estimates.last.to_f
        return [] if baseline.zero?

        delta_pct = ((latest - baseline) / baseline * 100).abs
        return [] if delta_pct < DELTA_THRESHOLD_PCT

        return [] if recent_anomaly_exists?(stream.id)

        anomaly = Anomaly.create!(
          stream: stream,
          timestamp: Time.current,
          anomaly_type: "erv_divergence",
          confidence: 1.0,
          details: {
            delta_pct: delta_pct.round(2),
            from_erv_percent: baseline.round(2),
            to_erv_percent: latest.round(2),
            window_minutes: (WINDOW / 60).to_i
          }
        )
        [ anomaly.id ]
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("ErvDivergenceDetector: creation failed for stream #{stream.id} (#{e.message})")
        []
      end

      def self.recent_anomaly_exists?(stream_id)
        Anomaly.where(stream_id: stream_id, anomaly_type: "erv_divergence")
               .where("timestamp > ?", DEDUP_WINDOW.ago).exists?
      end

      private_class_method :recent_anomaly_exists?
    end
  end
end
