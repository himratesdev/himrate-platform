# frozen_string_literal: true

# BUG-010 PR2 (FR-038/039/040..043): PrometheusMetrics module — instrumentation API.
#
# Pre-launch: no-op stub — все methods log call-site вместо emit. Real Prometheus
# integration (gem + /metrics endpoint OR push gateway) deferred к PR3 hook-up.
# Workers + services already call this API — pre-launch their calls just log.

module PrometheusMetrics
  class << self
    def observe_ops(destination:, accessory:, action:, result:, duration_seconds: nil)
      log("observe_ops", destination: destination, accessory: accessory, action: action,
          result: result, duration_seconds: duration_seconds)
    end

    def observe_drift_active(destination:, accessory:, value:)
      log("observe_drift_active", destination: destination, accessory: accessory, value: value)
    end

    def observe_drift_mttr(destination:, accessory:, seconds:)
      log("observe_drift_mttr", destination: destination, accessory: accessory, seconds: seconds)
    end

    def observe_health_failure(destination:, accessory:)
      log("observe_health_failure", destination: destination, accessory: accessory)
    end

    def observe_rollback(destination:, accessory:, result:)
      log("observe_rollback", destination: destination, accessory: accessory, result: result)
    end

    def observe_downtime_cost(destination:, accessory:, cost_usd:)
      log("observe_downtime_cost", destination: destination, accessory: accessory, cost_usd: cost_usd)
    end

    private

    def log(metric, **labels)
      Rails.logger.info("PrometheusMetrics: #{metric} #{labels.inspect}") if defined?(Rails)
    end
  end
end
