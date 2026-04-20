# frozen_string_literal: true

# TASK-039 FR-019: Attribution worker — enqueued при создании anomaly из
# SignalComputeWorker. Delegates к Trends::Attribution::Pipeline.
#
# Queue: signals (matches AnomalyAlerter event source). Retry 3.
# No pg_advisory_lock — UPSERT через find_or_initialize_by in Pipeline
# safe against concurrent writes (unique constraint anomaly_id+source).
#
# Triggered:
#   - SignalComputeWorker — per new anomaly из AnomalyAlerter.check output
#   - Backfill rake trends:reprocess_attributions для existing anomalies

module Trends
  class AnomalyAttributionWorker
    include Sidekiq::Job
    sidekiq_options queue: :signals, retry: 3

    def perform(anomaly_id)
      anomaly = Anomaly.find_by(id: anomaly_id)
      unless anomaly
        Rails.logger.warn("Trends::AnomalyAttributionWorker: anomaly #{anomaly_id} not found")
        return
      end

      results = Trends::Attribution::Pipeline.call(anomaly)
      Rails.logger.info(
        "Trends::AnomalyAttributionWorker: anomaly=#{anomaly_id} " \
        "attributions=#{results.size} sources=#{results.map(&:source).join(',')}"
      )
    end
  end
end
