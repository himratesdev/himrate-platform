# frozen_string_literal: true

# TASK-110 FR-021..023: Cross-device sync events backend canonical store.
# UNIQUE (user_id, event_hash) = idempotency (per FR-023: same event submitted twice → stored once).
# event_hash = SHA256(user_id || event_type || canonical_payload || synced_at_minute_bucket).
class CreateSyncEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :sync_events, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.string :event_type, null: false
      t.string :event_hash, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :device_fingerprint
      t.datetime :synced_at, null: false

      t.timestamps
    end

    add_index :sync_events, %i[user_id event_hash], unique: true
    add_index :sync_events, %i[user_id synced_at], order: { synced_at: :desc }
  end
end
