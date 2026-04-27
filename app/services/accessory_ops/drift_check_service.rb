# frozen_string_literal: true

# BUG-010 PR2 (ADR DEC-25, FR-133/134): drift detection via `kamal accessory details`.
# More portable к future Kamal API changes than raw `docker inspect`.
#
# Returns Result struct: drift_state (:match | :mismatch), declared_image, runtime_image.
# Caller (AccessoryDriftDetectorWorker) handles event lifecycle.

require "open3"
require "yaml"

module AccessoryOps
  class DriftCheckService
    Result = Struct.new(:drift_state, :declared_image, :runtime_image, keyword_init: true)

    DEPLOY_YML = Rails.root.join("config/deploy.yml")
    # Allowlist + literal container-name map для defense-in-depth против command injection
    # (Brakeman flagged ssh+docker inspect interpolation). Hash lookup → Brakeman трекает
    # literal strings safely. All callers eventually source accessory из workflow choice
    # enum OR worker constant, но enforce здесь explicitly.
    CONTAINER_NAMES = {
      "db"                      => "himrate-db",
      "redis"                   => "himrate-redis",
      "grafana"                 => "himrate-grafana",
      "prometheus"              => "himrate-prometheus",
      "loki"                    => "himrate-loki",
      "alertmanager"            => "himrate-alertmanager",
      "promtail"                => "himrate-promtail",
      "prometheus-pushgateway"  => "himrate-prometheus-pushgateway"
    }.freeze
    ALLOWED_ACCESSORIES = CONTAINER_NAMES.keys.freeze
    ALLOWED_DESTINATIONS = %w[staging production].freeze

    def self.call(destination:, accessory:)
      validate_inputs!(destination, accessory)
      declared = declared_image_for(accessory)
      runtime = runtime_image_for(destination: destination, accessory: accessory)

      state = if declared.nil? || runtime.nil? || declared != runtime
                :mismatch
      else
                :match
      end

      Result.new(drift_state: state, declared_image: declared, runtime_image: runtime)
    end

    def self.declared_image_for(accessory)
      yaml = YAML.load_file(DEPLOY_YML, permitted_classes: [ Symbol ])
      yaml.dig("accessories", accessory, "image")
    end

    def self.runtime_image_for(destination:, accessory:)
      host = AccessoryHostsConfig.hosts_for(destination).first
      # Hash lookup gives literal container name (Brakeman-safe), validate_inputs! гарантирует
      # accessory ∈ CONTAINER_NAMES.keys и destination ∈ ALLOWED_DESTINATIONS до сюда.
      container = CONTAINER_NAMES.fetch(accessory)
      remote_cmd = "docker inspect " + container + " --format '{{.Config.Image}}'"
      command = [ "ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new",
                 "root@" + host.to_s,
                 remote_cmd ]
      output, status = Open3.capture2e(*command)
      return nil unless status.exitstatus.zero?

      output.strip.presence
    end

    def self.validate_inputs!(destination, accessory)
      unless ALLOWED_DESTINATIONS.include?(destination)
        raise ArgumentError, "DriftCheckService: invalid destination=#{destination.inspect}"
      end

      unless ALLOWED_ACCESSORIES.include?(accessory)
        raise ArgumentError, "DriftCheckService: invalid accessory=#{accessory.inspect}"
      end
    end

    private_class_method :declared_image_for, :runtime_image_for, :validate_inputs!
  end
end
