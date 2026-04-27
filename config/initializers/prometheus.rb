# frozen_string_literal: true

# BUG-010 PR3 (FR-038..043, ADR DEC-7): PrometheusMetrics — push к prometheus-pushgateway.
# Pushgateway accessory deployed в PR1 (himrate-prometheus-pushgateway:9091), scraped Prometheus
# every 30s. Workers/services push текущее состояние; Prometheus stores series для dashboards
# (PR1 grafana/dashboards/*.json) + alert routing (PR1 alertmanager).
#
# Gauge semantics: каждая push overrides last value для (job, grouping labels) tuple. Idempotent —
# repeated push с тем же label set updates timestamp, не creates duplicate series.
#
# Failure handling: pushgateway unreachable → log warn + return. Никогда не raise — drift
# detection / health check / cost aggregation продолжаются без metrics. Прометеус scrape
# самой pushgateway покажет gap → operators visible.

require "net/http"
require "uri"

module PrometheusMetrics
  PUSHGATEWAY_URL = ENV.fetch("PROMETHEUS_PUSHGATEWAY_URL", "http://himrate-prometheus-pushgateway:9091")
  TIMEOUT_SECONDS = 3

  class << self
    # Last action duration + result per (destination, accessory, action). Gauge — overrides на каждый push.
    def observe_ops(destination:, accessory:, action:, result:, duration_seconds: nil)
      lines = []
      if duration_seconds
        lines << "# HELP accessory_ops_last_action_duration_seconds Duration last accessory operation"
        lines << "# TYPE accessory_ops_last_action_duration_seconds gauge"
        lines << build_metric("accessory_ops_last_action_duration_seconds",
                              { action: action, result: result }, duration_seconds.to_f)
      end
      lines << "# HELP accessory_ops_last_action_timestamp_seconds Unix ts последней операции"
      lines << "# TYPE accessory_ops_last_action_timestamp_seconds gauge"
      lines << build_metric("accessory_ops_last_action_timestamp_seconds",
                            { action: action, result: result }, Time.current.to_i)
      push("accessory_ops", grouping: { destination: destination, accessory: accessory }, body: lines.join("\n") + "\n")
    end

    # Drift state: 1 = open drift event, 0 = resolved. Gauge.
    def observe_drift_active(destination:, accessory:, value:)
      body = [
        "# HELP accessory_drift_active 1 если open drift event для (destination, accessory)",
        "# TYPE accessory_drift_active gauge",
        build_metric("accessory_drift_active", {}, value.to_i)
      ].join("\n") + "\n"
      push("accessory_drift", grouping: { destination: destination, accessory: accessory }, body: body)
    end

    # MTTR последнего resolved drift (seconds). Gauge — populated when worker closes event.
    def observe_drift_mttr(destination:, accessory:, seconds:)
      body = [
        "# HELP accessory_drift_last_mttr_seconds Время до resolution последнего drift",
        "# TYPE accessory_drift_last_mttr_seconds gauge",
        build_metric("accessory_drift_last_mttr_seconds", {}, seconds.to_i)
      ].join("\n") + "\n"
      push("accessory_drift", grouping: { destination: destination, accessory: accessory }, body: body)
    end

    # Health check failure event. Gauge — Unix timestamp последнего failure.
    def observe_health_failure(destination:, accessory:)
      body = [
        "# HELP accessory_health_last_failure_timestamp_seconds Unix ts последнего health check failure",
        "# TYPE accessory_health_last_failure_timestamp_seconds gauge",
        build_metric("accessory_health_last_failure_timestamp_seconds", {}, Time.current.to_i)
      ].join("\n") + "\n"
      push("accessory_health", grouping: { destination: destination, accessory: accessory }, body: body)
    end

    # Rollback event. Gauge — Unix timestamp + result label.
    def observe_rollback(destination:, accessory:, result:)
      body = [
        "# HELP accessory_rollback_last_timestamp_seconds Unix ts последнего rollback attempt",
        "# TYPE accessory_rollback_last_timestamp_seconds gauge",
        build_metric("accessory_rollback_last_timestamp_seconds", { result: result }, Time.current.to_i)
      ].join("\n") + "\n"
      push("accessory_rollback", grouping: { destination: destination, accessory: accessory }, body: body)
    end

    # Aggregated cost per (destination, accessory). Gauge — replaced on each daily aggregator run.
    def observe_downtime_cost(destination:, accessory:, cost_usd:)
      body = [
        "# HELP accessory_downtime_cost_usd Latest aggregated downtime cost USD",
        "# TYPE accessory_downtime_cost_usd gauge",
        build_metric("accessory_downtime_cost_usd", {}, cost_usd.to_f)
      ].join("\n") + "\n"
      push("accessory_cost", grouping: { destination: destination, accessory: accessory }, body: body)
    end

    # Cleanup stale grouping keys. Called периодически из CleanupWorker (FR-103) — удаляет
    # grouping keys где ни одной activity за last 7 days.
    def delete_grouping(job:, grouping:)
      uri = URI.join(PUSHGATEWAY_URL, "/metrics/" + path_for(job, grouping))
      request = Net::HTTP::Delete.new(uri)
      Net::HTTP.start(uri.hostname, uri.port,
                      open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) { |http| http.request(request) }
      :ok
    rescue StandardError => e
      Rails.logger.warn("PrometheusMetrics: delete_grouping failed — #{e.class}: #{e.message}") if defined?(Rails)
      :failed
    end

    private

    def build_metric(name, labels, value)
      formatted_labels = labels.map { |k, v| %(#{k}="#{escape_label(v)}") }.join(",")
      labels_part = formatted_labels.empty? ? "" : "{#{formatted_labels}}"
      "#{name}#{labels_part} #{value}"
    end

    def escape_label(value)
      value.to_s.gsub("\\", "\\\\").gsub('"', '\"').gsub("\n", '\n')
    end

    def path_for(job, grouping)
      # Pushgateway expects /job/<JOB>/<LABEL_NAME>/<LABEL_VALUE>... encoding для grouping labels.
      # ADR DEC-7: per-pair grouping предотвращает write collisions concurrent pushes.
      parts = [ "job", encode(job) ]
      grouping.each { |k, v| parts << encode(k.to_s) << encode(v.to_s) }
      parts.join("/")
    end

    def encode(value)
      # Allow only alnum + _ + - в pushgateway URL path segments. Defense-in-depth — labels
      # validated callers (allowlists в DriftCheckService etc), но enforce здесь explicitly.
      value.to_s.gsub(/[^a-zA-Z0-9_\-]/, "_")
    end

    def push(job, grouping:, body:)
      uri = URI.join(PUSHGATEWAY_URL, "/metrics/" + path_for(job, grouping))
      request = Net::HTTP::Post.new(uri, "Content-Type" => "text/plain; version=0.0.4")
      request.body = body
      Net::HTTP.start(uri.hostname, uri.port,
                      open_timeout: TIMEOUT_SECONDS, read_timeout: TIMEOUT_SECONDS) { |http| http.request(request) }
      :ok
    rescue StandardError => e
      Rails.logger.warn("PrometheusMetrics: push failed (job=#{job}) — #{e.class}: #{e.message}") if defined?(Rails)
      :failed
    end
  end
end
