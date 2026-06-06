# frozen_string_literal: true

require "net/http"
require "json"
require "concurrent"

module PoDebug
  # Block 5 — VPS host metrics via existing Prometheus accessory.
  #
  # Queries himrate-prometheus:9090 /api/v1/query for each metric in parallel
  # via a Concurrent::FixedThreadPool. Bounded ≤3s per query AND ≤3s total
  # via Concurrent::Promises.zip + timeout — sequential fallback would block
  # the Puma worker for up to N×3s if Prometheus is reachable-but-slow.
  #
  # CPU count read from a Prometheus query (count of node_cpu_seconds_total
  # series with mode=idle) so a future VPS upgrade only needs the scrape
  # target updated, not application code.
  class VpsHealth
    HTTP_TIMEOUT = 3 # seconds per Prometheus query
    PARALLEL_WORKERS = 4
    OVERALL_TIMEOUT = 5 # seconds budget for the whole block

    METRICS = {
      load_1m: 'node_load1{instance=~".*:9100"}',
      load_5m: 'node_load5{instance=~".*:9100"}',
      load_15m: 'node_load15{instance=~".*:9100"}',
      mem_total_bytes: 'node_memory_MemTotal_bytes{instance=~".*:9100"}',
      mem_available_bytes: 'node_memory_MemAvailable_bytes{instance=~".*:9100"}',
      swap_total_bytes: 'node_memory_SwapTotal_bytes{instance=~".*:9100"}',
      swap_free_bytes: 'node_memory_SwapFree_bytes{instance=~".*:9100"}',
      disk_util_pct: 'rate(node_disk_io_time_seconds_total{device="sda"}[1m]) * 100',
      cpu_iowait_pct: 'avg by (instance) (rate(node_cpu_seconds_total{mode="iowait"}[1m])) * 100',
      uptime_sec: "node_time_seconds - node_boot_time_seconds",
      cpu_count: 'count(count by (cpu) (node_cpu_seconds_total{mode="idle"}))'
    }.freeze

    def self.call
      new.call
    end

    def call
      values = parallel_query(METRICS)

      mem_total_mib = bytes_to_mib(values[:mem_total_bytes])
      mem_avail_mib = bytes_to_mib(values[:mem_available_bytes])
      swap_total_mib = bytes_to_mib(values[:swap_total_bytes])
      swap_free_mib = bytes_to_mib(values[:swap_free_bytes])
      cpu_count = values[:cpu_count]&.to_i

      {
        load: {
          one_min: values[:load_1m],
          five_min: values[:load_5m],
          fifteen_min: values[:load_15m],
          cpu_count: cpu_count
        },
        memory: {
          total_mib: mem_total_mib,
          available_mib: mem_avail_mib,
          used_mib: mem_total_mib && mem_avail_mib ? (mem_total_mib - mem_avail_mib).round(0) : nil,
          used_pct: mem_total_mib && mem_avail_mib && mem_total_mib.positive? ?
                      (((mem_total_mib - mem_avail_mib) / mem_total_mib.to_f) * 100).round(1) : nil
        },
        swap: {
          total_mib: swap_total_mib,
          free_mib: swap_free_mib,
          used_mib: swap_total_mib && swap_free_mib ? (swap_total_mib - swap_free_mib).round(0) : nil,
          used_pct: swap_total_mib && swap_free_mib && swap_total_mib.positive? ?
                      (((swap_total_mib - swap_free_mib) / swap_total_mib.to_f) * 100).round(1) : nil
        },
        disk: {
          util_pct: values[:disk_util_pct]&.round(1),
          iowait_pct: values[:cpu_iowait_pct]&.round(1)
        },
        uptime_hours: values[:uptime_sec] ? (values[:uptime_sec] / 3600.0).round(1) : nil,
        source: "prometheus",
        prometheus_url: prometheus_host
      }
    end

    private

    # CR S-1: read ENV per request so a Kamal env update lands without app
    # restart. Trivial overhead (single Hash lookup) vs class-load capture.
    def prometheus_host
      ENV.fetch("PROMETHEUS_URL", "http://himrate-prometheus:9090")
    end

    def parallel_query(metrics)
      pool = Concurrent::FixedThreadPool.new(PARALLEL_WORKERS)
      futures = metrics.map do |key, promql|
        future = Concurrent::Promises.future_on(pool) { [ key, query(promql) ] }
        [ key, future ]
      end
      Concurrent::Promises.zip(*futures.map(&:last)).value!(OVERALL_TIMEOUT)
      futures.to_h.transform_values { |f| f.fulfilled? ? f.value.last : nil }
    rescue Concurrent::TimeoutError
      Rails.logger.tagged("po_debug").warn("vps prom queries exceeded #{OVERALL_TIMEOUT}s — returning partial")
      futures.to_h.transform_values { |f| f.fulfilled? ? f.value.last : nil }
    ensure
      pool&.shutdown
    end

    def query(promql)
      uri = URI("#{prometheus_host}/api/v1/query")
      uri.query = URI.encode_www_form(query: promql)

      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = HTTP_TIMEOUT
      http.read_timeout = HTTP_TIMEOUT

      res = http.get(uri.request_uri)
      return nil unless res.is_a?(Net::HTTPSuccess)

      body = JSON.parse(res.body)
      return nil unless body["status"] == "success"

      result = body.dig("data", "result")
      return nil unless result.is_a?(Array) && result.any?

      value_pair = result.first["value"]
      return nil unless value_pair.is_a?(Array) && value_pair.size == 2

      Float(value_pair[1])
    rescue StandardError => e
      Rails.logger.tagged("po_debug").debug("vps prom query failed (#{promql}): #{e.class}")
      nil
    end

    def bytes_to_mib(value)
      return nil unless value

      (value / 1024.0 / 1024.0).round(0)
    end
  end
end
