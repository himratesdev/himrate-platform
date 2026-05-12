# frozen_string_literal: true

# TASK-086 FR-042 (ADR-086 §4.8): self-healing — if a cleanup table's last 3
# audit rows are all `error`, disable Flipper flag :cleanup_worker (kill switch)
# and fire a critical Alertmanager alert. Manual re-enable after the fix.
#
# Pattern mirrors AccessoryOps::AutoRemediation::TriggerService auto-disable.

module Cleanup
  class AutoDisableService
    CONSECUTIVE_ERROR_THRESHOLD = 3
    FLAG = :cleanup_worker

    def self.check_and_disable!
      tables_with_consecutive_errors.each do |table_name|
        disable_and_alert!(table_name)
      end
    end

    def self.tables_with_consecutive_errors
      CleanupAuditLog.distinct.pluck(:table_name).select { |t| consecutive_errors?(t) }
    end

    def self.consecutive_errors?(table_name)
      recent = CleanupAuditLog.recent_for_table(table_name, limit: CONSECUTIVE_ERROR_THRESHOLD).to_a
      recent.size == CONSECUTIVE_ERROR_THRESHOLD && recent.all? { |row| row.status == "error" }
    end

    def self.disable_and_alert!(table_name)
      return unless Flipper.enabled?(FLAG)

      Flipper.disable(FLAG)
      Rails.logger.error("cleanup_worker: auto-disabled — 3 consecutive errors on table=#{table_name}")
      AlertmanagerNotifier.push(
        labels: { alertname: "cleanup_worker_auto_disabled", severity: "critical", subsystem: "cleanup_worker", table: table_name.to_s },
        annotations: { summary: "CleanupWorker auto-disabled: 3 consecutive errors on #{table_name}. Investigate, fix, then Flipper.enable(:cleanup_worker)." }
      )
    rescue StandardError => e
      Rails.logger.error("cleanup_worker: auto-disable notify failed — #{e.class}: #{e.message}")
    end

    private_class_method :tables_with_consecutive_errors, :consecutive_errors?, :disable_and_alert!
  end
end
