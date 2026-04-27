# frozen_string_literal: true

# BUG-010 PR2 (FR-083..094, ADR DEC-16): auto-remediation trigger.
# Worker calls when drift event opened AND Flipper flag enabled.
# Cool-down (24h) + max-attempts (3/72h then auto-disable) + GitHub API workflow_dispatch.

require "net/http"

module AccessoryOps
  module AutoRemediation
    class TriggerService
      Result = Struct.new(:result, :log_id, :error, keyword_init: true)

      WORKFLOW_FILE = "accessory-ops.yml"
      WORKFLOW_REF = "main"
      GITHUB_API_HOST = "api.github.com"
      REPO = "himratesdev/himrate-platform"

      def self.call(destination:, accessory:, drift_event_id:)
        return skip(:disabled) unless flag_enabled?

        if AutoRemediationLog.disabled_for?(destination: destination, accessory: accessory)
          return skip(:auto_disabled, destination: destination, accessory: accessory, drift_event_id: drift_event_id)
        end

        if AutoRemediationLog.cool_down_active?(destination: destination, accessory: accessory)
          return skip(:skip_cooldown, destination: destination, accessory: accessory, drift_event_id: drift_event_id)
        end

        if AutoRemediationLog.max_attempts_exceeded?(destination: destination, accessory: accessory)
          auto_disable!(destination: destination, accessory: accessory, drift_event_id: drift_event_id)
          return Result.new(result: :skip_max_attempts)
        end

        attempt = next_attempt_number(destination: destination, accessory: accessory)

        api_result = dispatch_workflow(destination: destination, accessory: accessory,
                                       drift_event_id: drift_event_id)

        log = AutoRemediationLog.create!(
          destination: destination,
          accessory: accessory,
          drift_event_id: drift_event_id,
          triggered_at: Time.current,
          result: api_result.success? ? "triggered" : "api_error",
          attempt_number: attempt
        )

        Result.new(result: api_result.success? ? :triggered : :api_error,
                   log_id: log.id, error: api_result.error)
      end

      def self.flag_enabled?
        Flipper.enabled?(:accessory_auto_remediation)
      end

      def self.skip(result_sym, destination: nil, accessory: nil, drift_event_id: nil)
        log = nil
        if destination && accessory
          log = AutoRemediationLog.create!(
            destination: destination,
            accessory: accessory,
            drift_event_id: drift_event_id,
            triggered_at: Time.current,
            result: result_sym.to_s,
            attempt_number: next_attempt_number(destination: destination, accessory: accessory)
          )
        end
        Result.new(result: result_sym, log_id: log&.id)
      end

      def self.next_attempt_number(destination:, accessory:)
        AutoRemediationLog.for_pair(destination, accessory).maximum(:attempt_number).to_i + 1
      end

      def self.auto_disable!(destination:, accessory:, drift_event_id:)
        AutoRemediationLog.create!(
          destination: destination,
          accessory: accessory,
          drift_event_id: drift_event_id,
          triggered_at: Time.current,
          result: "auto_disabled",
          attempt_number: next_attempt_number(destination: destination, accessory: accessory),
          disabled_at: Time.current,
          disable_reason: "max_attempts_exhausted_3_in_72h"
        )
      end

      def self.dispatch_workflow(destination:, accessory:, drift_event_id:)
        token = ENV.fetch("AUTO_TRIGGER_GH_PAT")
        uri = URI("https://#{GITHUB_API_HOST}/repos/#{REPO}/actions/workflows/#{WORKFLOW_FILE}/dispatches")

        body = {
          ref: WORKFLOW_REF,
          inputs: {
            destination: destination,
            accessory: accessory,
            action: "reboot",
            triggered_by: "auto_remediation",
            auto_remediation_event_id: drift_event_id.to_s
          }
        }

        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = "Bearer #{token}"
        request["Accept"] = "application/vnd.github+json"
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)

        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
          http.request(request)
        end

        ApiResult.new(success?: response.code.to_i == 204, error: response.code != "204" ? response.body : nil)
      rescue StandardError => e
        ApiResult.new(success?: false, error: "#{e.class}: #{e.message}")
      end

      ApiResult = Struct.new(:success?, :error, keyword_init: true)

      private_class_method :flag_enabled?, :skip, :next_attempt_number, :auto_disable!, :dispatch_workflow
    end
  end
end
