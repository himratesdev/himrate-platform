# frozen_string_literal: true

require "net/http"
require "json"

module PoDebug
  # Block 5 — VPS host metrics via existing Prometheus accessory.
  #
  # Calls himrate-prometheus:9090 /api/v1/query for each metric. If Prometheus
  # accessory unavailable (after T1 PR-B1c disables observability) → returns
  # { error: ..., stale: true } and v1.0 swaps source.
  #
  # Pure HTTP, no extra gems. Timeout 3s per query, 4 queries → ≤12s worst case;
  # cached 5s upstream by Aggregator.
  class VpsHealth
    PROM_HOST = ENV.fetch("PROMETHEUS_URL", "http://himrate-prometheus:9090")
    HTTP_TIMEOUT = 3 # seconds

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
      uptime_sec: "node_time_seconds - node_boot_time_seconds"
    }.freeze

    def self.call
      new.call
    end

    def call
      values = METRICS.transform_values { |q| query(q) }

      mem_total_mib = bytes_to_mib(values[:mem_total_bytes])
      mem_avail_mib = bytes_to_mib(values[:mem_available_bytes])
      swap_total_mib = bytes_to_mib(values[:swap_total_bytes])
      swap_free_mib = bytes_to_mib(values[:swap_free_bytes])

      {
        load: {
          one_min: values[:load_1m],
          five_min: values[:load_5m],
          fifteen_min: values[:load_15m]
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
        prometheus_url: PROM_HOST
      }
    end

    private

    def query(promql)
      uri = URI("#{PROM_HOST}/api/v1/query")
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

      # Take the first instance value; multi-instance scrape would aggregate upstream.
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
