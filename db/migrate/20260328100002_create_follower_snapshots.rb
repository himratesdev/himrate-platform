# frozen_string_literal: true

# TASK-017: Follower snapshots for Growth Pattern tracking.

class CreateFollowerSnapshots < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :follower_snapshots, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true, index: false
      t.datetime :timestamp, null: false
      t.integer :followers_count, null: false
      t.integer :new_followers_24h
    end

    add_index :follower_snapshots, %i[channel_id timestamp],
      name: "idx_follower_snapshots_channel_time", algorithm: :concurrently, if_not_exists: true
  end

  def down
    drop_table :follower_snapshots
  end
end
