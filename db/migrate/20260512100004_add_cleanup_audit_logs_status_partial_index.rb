# frozen_string_literal: true

# TASK-086 FR-036: partial index on cleanup_audit_logs for "find errors in the
# last 7d" queries (Alertmanager rule cleanup_worker_health + auto-disable check
# FR-042). `WHERE status != 0` keeps it tiny (success rows excluded).
#
# CONCURRENTLY → non-blocking build, requires disable_ddl_transaction!.

class AddCleanupAuditLogsStatusPartialIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :cleanup_audit_logs, %i[status run_at],
      name: "idx_cleanup_audit_logs_errors",
      where: "status != 0",
      order: { run_at: :desc },
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :cleanup_audit_logs, name: "idx_cleanup_audit_logs_errors", algorithm: :concurrently, if_exists: true
  end
end
