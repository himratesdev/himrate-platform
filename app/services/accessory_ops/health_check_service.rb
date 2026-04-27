# frozen_string_literal: true

# BUG-010 PR2 (ADR DEC-9, FR-128/129/130): per-accessory semantic health check.
# Strategy pattern по accessory type (pg_isready, redis-cli ping, HTTP /health endpoints).
# Used by workflow steps (post-restart polling) + AccessoryDriftDetectorWorker (optional periodic).

require "open3"

module AccessoryOps
  class HealthCheckService
    Result = Struct.new(:healthy, :status, :raw_output, keyword_init: true) do
      def healthy?
        healthy
      end
    end

    TIMEOUT_SECONDS = 5

    HEALTH_COMMANDS = {
      "db" => ->(host) {
        ssh(host, "docker exec himrate-db pg_isready -U himrate -d himrate_production")
      },
      "redis" => ->(host) {
        ssh(host, "docker exec himrate-redis redis-cli ping")
      },
      "grafana" => ->(host) {
        ssh(host, "curl -sf -m #{TIMEOUT_SECONDS} http://himrate-grafana:3000/api/health")
      },
      "prometheus" => ->(host) {
        ssh(host, "curl -sf -m #{TIMEOUT_SECONDS} http://himrate-prometheus:9090/-/healthy")
      },
      "prometheus-pushgateway" => ->(host) {
        ssh(host, "curl -sf -m #{TIMEOUT_SECONDS} http://himrate-prometheus-pushgateway:9091/-/healthy")
      },
      "loki" => ->(host) {
        ssh(host, "curl -sf -m #{TIMEOUT_SECONDS} http://himrate-loki:3100/ready")
      },
      "promtail" => ->(host) {
        ssh(host, "curl -sf -m #{TIMEOUT_SECONDS} http://himrate-promtail:9080/ready")
      },
      "alertmanager" => ->(host) {
        ssh(host, "curl -sf -m #{TIMEOUT_SECONDS} http://himrate-alertmanager:9093/-/healthy")
      }
    }.freeze

    def self.call(destination:, accessory:)
      host = AccessoryHostsConfig.hosts_for(destination).first
      command = HEALTH_COMMANDS[accessory]
      return Result.new(healthy: false, status: "no_check_method", raw_output: "") unless command

      output, exit_status = command.call(host)
      Result.new(
        healthy: exit_status.zero?,
        status: exit_status.zero? ? "healthy" : "unhealthy",
        raw_output: output.to_s.strip
      )
    end

    def self.ssh(host, remote_command)
      ssh_command = ["ssh", "-o", "ConnectTimeout=#{TIMEOUT_SECONDS}",
                     "-o", "StrictHostKeyChecking=accept-new",
                     "root@#{host}", remote_command]
      output, status = Open3.capture2e(*ssh_command)
      [output, status.exitstatus]
    rescue StandardError => e
      ["#{e.class}: #{e.message}", 1]
    end
    private_class_method :ssh
  end
end
