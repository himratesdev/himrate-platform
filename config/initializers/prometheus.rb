# frozen_string_literal: true

# BUG-010 PR2 (FR-038/039/040..043): Prometheus metrics registration.
# Mounts /metrics endpoint в Rails app (config/routes.rb). Workflow steps + workers push
# metrics through PrometheusMetrics module. Prometheus accessory scrapes /metrics every 30s
# (config/prometheus/prometheus.yml).

require "prometheus_exporter/middleware"
require "prometheus_exporter/instrumentation"
require "prometheus_exporter/server"

return if Rails.env.test?

# Embedded mode: Rails app exposes /metrics directly (no separate prometheus_exporter server
# process). Suitable для single-app monolith — no IPC overhead.
PrometheusExporter::Client.default = PrometheusExporter::LocalClient.new(
  collector: PrometheusExporter::Server::Collector.new
)

# Module wrapper for app code → keeps metric registration в одном месте.
module PrometheusMetrics
  class << self
    def collector
      PrometheusExporter::Client.default.send(:collector)
    end

    def register_metrics
      @ops_total ||= collector.register(:counter, "accessory_ops_total",
        "Total accessory operations triggered").tap do |c|
          # Initial registration; labels supplied per increment call
          c.observe(0, destination: "_init", accessory: "_init", action: "_init", result: "_init")
        end

      @ops_duration ||= collector.register(:histogram, "accessory_ops_duration_seconds",
        "Accessory operation duration").tap do |h|
          h.observe(0, destination: "_init", accessory: "_init", action: "_init")
        end

      @drift_active ||= collector.register(:gauge, "accessory_drift_active",
        "Active drift events (1=open, 0=closed)").tap do |g|
          g.observe(0, destination: "_init", accessory: "_init")
        end

      @drift_mttr ||= collector.register(:histogram, "accessory_drift_mttr_seconds",
        "Drift Mean Time To Resolution").tap do |h|
          h.observe(0, destination: "_init", accessory: "_init")
        end

      @health_failures ||= collector.register(:counter, "accessory_health_check_failures_total",
        "Health check failures").tap do |c|
          c.observe(0, destination: "_init", accessory: "_init")
        end

      @rollback_total ||= collector.register(:counter, "accessory_rollback_total",
        "Rollback attempts").tap do |c|
          c.observe(0, destination: "_init", accessory: "_init", result: "_init")
        end

      @downtime_cost ||= collector.register(:counter, "accessory_downtime_cost_usd",
        "Estimated downtime cost USD").tap do |c|
          c.observe(0, destination: "_init", accessory: "_init")
        end
    end

    def observe_ops(destination:, accessory:, action:, result:, duration_seconds: nil)
      collector.process("accessory_ops_total#{labels(destination: destination, accessory: accessory, action: action, result: result)} 1")
      if duration_seconds
        collector.process("accessory_ops_duration_seconds#{labels(destination: destination, accessory: accessory, action: action)} #{duration_seconds}")
      end
    end

    def observe_drift_active(destination:, accessory:, value:)
      collector.process("accessory_drift_active#{labels(destination: destination, accessory: accessory)} #{value}")
    end

    def observe_drift_mttr(destination:, accessory:, seconds:)
      collector.process("accessory_drift_mttr_seconds#{labels(destination: destination, accessory: accessory)} #{seconds}")
    end

    def observe_health_failure(destination:, accessory:)
      collector.process("accessory_health_check_failures_total#{labels(destination: destination, accessory: accessory)} 1")
    end

    def observe_rollback(destination:, accessory:, result:)
      collector.process("accessory_rollback_total#{labels(destination: destination, accessory: accessory, result: result)} 1")
    end

    def observe_downtime_cost(destination:, accessory:, cost_usd:)
      collector.process("accessory_downtime_cost_usd#{labels(destination: destination, accessory: accessory)} #{cost_usd}")
    end

    private

    def labels(**pairs)
      "{#{pairs.map { |k, v| %(#{k}="#{v}") }.join(',')}}"
    end
  end
end

PrometheusMetrics.register_metrics
