# frozen_string_literal: true

# TASK-086: test env loads structure.sql without data, so the SignalConfiguration
# retention rows seeded by 20260512100001_seed_cleanup_retention_thresholds are absent.
# This helper re-applies them (same content as the migration; idempotent).
module CleanupRetentionConfigSeeder
  module_function

  CONFIGS = [
    [ "trust_index_histories", "default", "retention_days", 90 ],
    [ "cleanup", "ti_signals", "retention_days", 90 ],
    [ "cleanup", "ccv_snapshots", "retention_days", 90 ],
    [ "cleanup", "chatters_snapshots", "retention_days", 90 ],
    [ "cleanup", "chat_messages", "retention_days", 90 ]
  ].freeze

  def seed!
    now = Time.current
    rows = CONFIGS.map do |signal_type, category, param_name, param_value|
      { signal_type: signal_type, category: category, param_name: param_name,
        param_value: param_value, created_at: now, updated_at: now }
    end
    SignalConfiguration.upsert_all(rows, unique_by: %i[signal_type category param_name], on_duplicate: :skip)
    ActiveSupport::CurrentAttributes.clear_all
  end
end
