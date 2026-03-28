# frozen_string_literal: true

# TASK-017: Cross-channel presence tracking (Signal #8).
# Tracks which users appear on which channels simultaneously.

class CreateCrossChannelPresences < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :cross_channel_presences, id: :uuid do |t|
      t.string :username, limit: 255, null: false
      t.references :channel, type: :uuid, null: false, foreign_key: true, index: false
      t.references :stream, type: :uuid, foreign_key: true, index: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :message_count, null: false, default: 0
    end

    add_index :cross_channel_presences, %i[username channel_id],
      unique: true, name: "idx_cross_channel_user_channel", algorithm: :concurrently, if_not_exists: true
    add_index :cross_channel_presences, %i[channel_id stream_id],
      name: "idx_cross_channel_channel_stream", algorithm: :concurrently, if_not_exists: true
  end

  def down
    drop_table :cross_channel_presences
  end
end
