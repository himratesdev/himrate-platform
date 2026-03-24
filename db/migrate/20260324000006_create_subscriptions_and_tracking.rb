# frozen_string_literal: true

class CreateSubscriptionsAndTracking < ActiveRecord::Migration[8.0]
  def change
    create_table :subscriptions, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.string :tier, limit: 20, null: false, default: "free"
      t.string :plan_type, limit: 20
      t.decimal :price, precision: 10, scale: 2
      t.datetime :started_at, null: false
      t.datetime :cancelled_at
      t.boolean :is_active, null: false, default: true

      t.timestamps
    end

    add_index :subscriptions, :is_active

    create_table :tracked_channels, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :subscription, type: :uuid, foreign_key: true
      t.datetime :added_at, null: false
      t.boolean :tracking_enabled, null: false, default: true
    end

    add_index :tracked_channels, [ :user_id, :channel_id ], unique: true
  end
end
