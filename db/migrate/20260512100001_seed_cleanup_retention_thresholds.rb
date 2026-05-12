# frozen_string_literal: true

# TASK-086 FR-006 + FR-019..022 + FR-031: seed retention_days config rows for
# CleanupWorker. Build-for-years — ALL retention horizons in DB, no hardcoded
# constants (replaces hardcoded `CleanupWorker::SIGNAL_TTL = 90.days`).
#
# Rows:
#   - ('trust_index_histories', 'default', 'retention_days', 90) — intermediate TIH
#     rolling window (per-stream final TIH + live TIH preserved forever, see FR-002/003).
#   - ('cleanup', 'ti_signals' | 'ccv_snapshots' | 'chatters_snapshots' | 'chat_messages',
#     'retention_days', 90) — the 4 pre-existing cleanup tables migrated off SIGNAL_TTL.
#
# cleanup_audit_logs retention = INDEFINITE per PO directive 2026-05-12 ("max data
# for Big Data / compliance") — NO retention row seeded; CleanupWorker skips it.
#
# Idempotent: upsert_all on_duplicate: :skip preserves admin-tuned values on
# db:migrate:redo / re-runs (TASK-039 pattern).

class SeedCleanupRetentionThresholds < ActiveRecord::Migration[8.0]
  CONFIGS = [
    [ "trust_index_histories", "default", "retention_days", 90 ],
    [ "cleanup", "ti_signals", "retention_days", 90 ],
    [ "cleanup", "ccv_snapshots", "retention_days", 90 ],
    [ "cleanup", "chatters_snapshots", "retention_days", 90 ],
    [ "cleanup", "chat_messages", "retention_days", 90 ]
  ].freeze

  def up
    now = Time.current
    rows = CONFIGS.map do |signal_type, category, param_name, param_value|
      { signal_type: signal_type, category: category, param_name: param_name,
        param_value: param_value, created_at: now, updated_at: now }
    end

    SignalConfiguration.upsert_all(rows,
      unique_by: %i[signal_type category param_name],
      on_duplicate: :skip)
  end

  def down
    SignalConfiguration.where(signal_type: "trust_index_histories", category: "default", param_name: "retention_days").delete_all
    SignalConfiguration.where(signal_type: "cleanup", category: %w[ti_signals ccv_snapshots chatters_snapshots chat_messages], param_name: "retention_days").delete_all
  end
end
