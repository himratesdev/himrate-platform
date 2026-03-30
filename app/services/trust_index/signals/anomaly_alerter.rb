# frozen_string_literal: true

# TASK-028 FR-017: Confidence-Weighted Anomaly Alerts.
# Auto-creates anomaly records when signal value > alert_threshold AND confidence >= 0.7.
# Deduplication: no duplicate anomaly for same stream + type within 5 minutes.

module TrustIndex
  module Signals
    class AnomalyAlerter
      DEFAULT_ALERT_THRESHOLD = 0.5
      MIN_CONFIDENCE = 0.7
      DEDUP_WINDOW = 5.minutes

      # Check all signal results and create anomaly records for triggered signals.
      # Returns array of created anomaly IDs.
      def self.check(stream, results, timestamp: Time.current)
        created = []

        results.each do |signal_type, signal_result|
          next unless signal_result.value && signal_result.confidence >= MIN_CONFIDENCE

          threshold = alert_threshold_for(signal_type)
          next unless signal_result.value > threshold

          # Deduplication: skip if recent anomaly exists for this stream + type
          next if recent_anomaly_exists?(stream.id, signal_type, timestamp)

          anomaly = Anomaly.create!(
            stream: stream,
            timestamp: timestamp,
            anomaly_type: signal_type,
            confidence: signal_result.confidence,
            details: {
              signal_value: signal_result.value.round(4),
              alert_threshold: threshold,
              signal_metadata: signal_result.metadata
            }
          )

          created << anomaly.id
        end

        created
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn("AnomalyAlerter: creation failed (#{e.message})")
        created
      end

      def self.alert_threshold_for(signal_type)
        SignalConfiguration.value_for(signal_type, "default", "alert_threshold").to_f
      rescue SignalConfiguration::ConfigurationMissing
        DEFAULT_ALERT_THRESHOLD
      end

      def self.recent_anomaly_exists?(stream_id, anomaly_type, timestamp)
        Anomaly.where(
          stream_id: stream_id,
          anomaly_type: anomaly_type
        ).where("timestamp > ?", timestamp - DEDUP_WINDOW).exists?
      end

      private_class_method :recent_anomaly_exists?
    end
  end
end
