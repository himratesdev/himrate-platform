# frozen_string_literal: true

# BUG-010 PR2: auto-remediation audit log + cool-down/max-attempts tracking.
# AutoRemediation::TriggerService inserts row per attempt. Cool-down query: 24h sliding
# window. Max-attempts: 3 per 72h, then auto-disable Flipper для (destination, accessory) pair.

class CreateAutoRemediationLog < ActiveRecord::Migration[8.0]
  def change
    create_table :auto_remediation_logs, id: :uuid do |t|
      t.string :destination, null: false
      t.string :accessory, null: false
      t.references :drift_event, type: :uuid, foreign_key: { to_table: :accessory_drift_events }
      t.timestamp :triggered_at, null: false
      t.string :result, null: false  # triggered/skip_cooldown/skip_max_attempts/api_error
      t.integer :attempt_number, null: false
      t.timestamp :disabled_at
      t.string :disable_reason
      t.timestamps
    end

    # Cool-down + max-attempts query: (destination, accessory) ordered by triggered_at DESC
    add_index :auto_remediation_logs,
              [:destination, :accessory, :triggered_at],
              order: { triggered_at: :desc },
              name: "idx_auto_remediation_recent"

    add_check_constraint :auto_remediation_logs,
                         "result IN ('triggered', 'skip_cooldown', 'skip_max_attempts', 'api_error', 'auto_disabled')",
                         name: "chk_auto_remediation_result"
  end
end
