# frozen_string_literal: true

# TASK-085 FR-014 (ADR-085 D-6): TI Drop Detector — extends signal_compute_worker chain.
# Reads TrustIndexHistory cross-stream (channel-scoped) за 30min window.
# Triggers anomaly если TI drop > 15 pts.
#
# ADR-085 D-6 cold_start precondition: skip if latest cold_start_status == 'insufficient'
# (false positive prevention для new clean channels с natural low TI).
#
# Reuses AnomalyAlerter dedup pattern (5min window per stream + anomaly_type) per FR-016.

module TrustIndex
  module Signals
    class TiDropDetector
      WINDOW = 30.minutes
      DROP_THRESHOLD_POINTS = 15.0
      DEDUP_WINDOW = 5.minutes

      # Check TrustIndexHistory для drop > 15 pts. Returns array of created anomaly IDs.
      def self.check(stream)
        history = TrustIndexHistory
          .where(channel_id: stream.channel_id)
          .where("calculated_at > ?", WINDOW.ago)
          .order(calculated_at: :desc)
          .pluck(:trust_index_score, :cold_start_status)

        return [] if history.size < 2

        # ADR D-6 precondition: skip cold-start period (insufficient data → noise alerts).
        latest_score, latest_cold_start = history.first
        return [] if latest_cold_start == "insufficient"

        baseline_score = history.last.first
        delta = baseline_score.to_f - latest_score.to_f
        return [] if delta < DROP_THRESHOLD_POINTS

        return [] if recent_anomaly_exists?(stream.id)

        anomaly = Anomaly.create!(
          stream: stream,
          timestamp: Time.current,
          anomaly_type: "ti_drop",
          confidence: 1.0,
          details: {
            delta_pts: delta.round(2),
            from_score: baseline_score.to_f.round(2),
            to_score: latest_score.to_f.round(2),
            window_minutes: (WINDOW / 60).to_i
          }
        )
        [ anomaly.id ]
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("TiDropDetector: creation failed for stream #{stream.id} (#{e.message})")
        []
      end

      def self.recent_anomaly_exists?(stream_id)
        Anomaly.where(stream_id: stream_id, anomaly_type: "ti_drop")
               .where("timestamp > ?", DEDUP_WINDOW.ago).exists?
      end

      private_class_method :recent_anomaly_exists?
    end
  end
end
