# frozen_string_literal: true

# TASK-017: Billing events log (provider-agnostic webhook idempotency).
# Supports YooKassa (MVP) + Stripe (future) via adapter pattern.

class CreateBillingEvents < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :billing_events, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      t.string :event_type, limit: 50, null: false
      t.string :provider, limit: 20, null: false
      t.string :provider_event_id, limit: 255, null: false
      t.decimal :amount, precision: 10, scale: 2
      t.string :currency, limit: 3
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :billing_events, :provider_event_id, unique: true,
      name: "idx_billing_events_provider_event", algorithm: :concurrently, if_not_exists: true
    add_index :billing_events, %i[user_id created_at],
      name: "idx_billing_events_user_time", algorithm: :concurrently, if_not_exists: true
  end

  def down
    drop_table :billing_events
  end
end
