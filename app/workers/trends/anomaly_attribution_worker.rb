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
      # CR S-3: SRS §10 monitoring — unified ensure pattern (matches
      # AggregationWorker). completed event fires на КАЖДЫЙ perform (success /
      # failure / not_found) — subscribers (StatsD/Prometheus) получают consistent
      # counter model. failed event — отдельный marker для rate alerts.
      start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      found = false
      attributions_count = 0

      anomaly = Anomaly.find_by(id: anomaly_id)
      unless anomaly
        Rails.logger.warn("Trends::AnomalyAttributionWorker: anomaly #{anomaly_id} not found")
        return
      end
      found = true

      results = Trends::Attribution::Pipeline.call(anomaly)
      attributions_count = results.size
      Rails.logger.info(
        "Trends::AnomalyAttributionWorker: anomaly=#{anomaly_id} " \
        "attributions=#{attributions_count} sources=#{results.map(&:source).join(',')}"
      )
    rescue StandardError => e
      ActiveSupport::Notifications.instrument(
        "trends.anomaly_attribution_worker.failed",
        anomaly_id: anomaly_id,
        error_class: e.class.name
      )
      raise
    ensure
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round(2)
      ActiveSupport::Notifications.instrument(
        "trends.anomaly_attribution_worker.completed",
        anomaly_id: anomaly_id,
        found: found,
        attributions_count: attributions_count,
        duration_ms: duration_ms
      )
    end
  end
end
