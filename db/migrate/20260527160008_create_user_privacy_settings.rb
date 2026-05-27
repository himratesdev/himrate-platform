# frozen_string_literal: true

# TASK-113 BE-1 (FR-014, M15): privacy/visibility-тогглы + consent-log (GDPR).
# PO decision: consent default ON (тогглы предзаполнены), КРОМЕ display_name_visible = OFF
# (стример видит псевдоним User_{hash} пока зритель явно не включит). EU-Planet49 deferred react-only.
class CreateUserPrivacySettings < ActiveRecord::Migration[8.0]
  def up
    create_table :user_privacy_settings, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.boolean :display_name_visible, null: false, default: false # OFF — псевдоним по умолчанию
      t.boolean :recognition, null: false, default: true
      t.boolean :chat_capture, null: false, default: true
      t.boolean :device_telemetry, null: false, default: true
      t.boolean :aggregated_stats, null: false, default: true
      t.jsonb :consent_log, null: false, default: [] # [{scope, granted_at}]
      t.timestamps
    end

    add_index :user_privacy_settings, :user_id, unique: true, name: "idx_user_privacy_unique"
  end

  def down
    drop_table :user_privacy_settings
  end
end
