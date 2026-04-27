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

    def self.call(destination:, accessory:)
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
      container = "himrate-#{accessory}"
      command = [ "ssh", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new",
                 "root@#{host}",
                 %(docker inspect #{container} --format '{{.Config.Image}}') ]
      output, status = Open3.capture2e(*command)
      return nil unless status.exitstatus.zero?

      output.strip.presence
    end

    private_class_method :declared_image_for, :runtime_image_for
  end
end
