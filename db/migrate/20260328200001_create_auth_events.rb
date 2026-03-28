# frozen_string_literal: true

# TASK-018 v1.1: Auth events tracking for observability.
# Tracks every auth attempt/success/failure. Detects consecutive failures → alerts.
# Events = Big Data asset (never delete).

class CreateAuthEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :auth_events, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: true, index: false, null: true
      t.string :provider, limit: 20, null: false
      t.string :result, limit: 20, null: false
      t.string :error_type, limit: 50
      t.inet :ip_address
      t.text :user_agent
      t.string :extension_version, limit: 20
      t.jsonb :metadata, null: false, default: {}

      t.datetime :created_at, null: false
    end

    add_index :auth_events, %i[user_id created_at],
      name: "idx_auth_events_user_time", algorithm: :concurrently, if_not_exists: true
    add_index :auth_events, %i[ip_address created_at],
      name: "idx_auth_events_ip_time", algorithm: :concurrently, if_not_exists: true
    add_index :auth_events, %i[provider result created_at],
      name: "idx_auth_events_provider_result_time", algorithm: :concurrently, if_not_exists: true
  end

  def down
    drop_table :auth_events
  end
end
