# frozen_string_literal: true

# TASK-086 FR-031 + FR-034/035 (ADR-086 §4.6 — SRS migrations #4+#6 merged per
# PO directive 2026-05-12: `:sql` schema format, migrations run from scratch each
# CI build → no point imitating "schema evolution"). One row per cleanup sub-run.
#
# Columns:
#   - run_at timestamptz NN — when this cleanup sub-run executed
#   - table_name string NN — 'tih' | 'ti_signals' | 'ccv_snapshots' | 'chatters_snapshots'
#                            | 'chat_messages' | 'sessions' | 'cleanup_audit_logs'
#   - status integer NN default 0 — enum success=0 / partial=1 / error=2 / skipped=3
#                                   (int, not string — partial index `WHERE status != 0` compact)
#   - deleted_count / archived_count bigint NN default 0 — overflow safety (build-for-years)
#   - duration_ms bigint — overflow safety (FR-035)
#   - error_code string nullable + error_context jsonb default {} — PII-safe structured
#     error storage (FR-034). NO free-text error_message column (GDPR).
#   - retention_days integer nullable — retention horizon applied this run (NULL = indefinite)
#   - created_at timestamptz NN default now() — DB default so raw INSERT works
#
# Index (run_at DESC, table_name) for "latest runs per table" queries.
# Partial index `(status, run_at DESC) WHERE status != 0` (FR-036) added separately
# CONCURRENTLY (it can't run inside the create_table transaction).

class CreateCleanupAuditLogs < ActiveRecord::Migration[8.0]
  def up
    create_table :cleanup_audit_logs, id: :uuid do |t|
      t.datetime :run_at, null: false
      t.string :table_name, null: false, limit: 50
      t.integer :status, null: false, default: 0
      t.bigint :deleted_count, null: false, default: 0
      t.bigint :archived_count, null: false, default: 0
      t.bigint :duration_ms
      t.string :error_code, limit: 100
      t.jsonb :error_context, null: false, default: {}
      t.integer :retention_days
      t.datetime :created_at, null: false, default: -> { "now()" }
    end

    add_index :cleanup_audit_logs, %i[run_at table_name],
      name: "idx_cleanup_audit_logs_run_at_table",
      order: { run_at: :desc }
  end

  def down
    drop_table :cleanup_audit_logs
  end
end
