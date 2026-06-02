# frozen_string_literal: true

# BUG-SCW-CROSS-CHANNEL: pre-aggregate (username → distinct_channels_24h) once per refresh cycle
# so SignalComputeWorker stops re-scanning the full 24h chat_messages partition for every live
# stream (root-caused 2026-06-02: full-scan O(N) over 12.34M-row 24h slice = 5-8s per call,
# 82-88% of total SCW work, blowing CH 1.12 GiB memory cap under concurrent load).
#
# Refresh worker writes ~50-100k rows / 5min via bulk upsert; ContextBuilder lookup becomes a
# single indexed PG SELECT per stream (vs the per-stream CH 24h scan it replaces). Username key
# follows Twitch login normalization (case-insensitive — citext) — IRC sends lowercase, but
# Apollo/cache can surface mixed-case usernames, so citext keeps lookups stable.

class CreateCrossChannelDigests < ActiveRecord::Migration[8.0]
  def up
    safety_assured do
      execute "CREATE EXTENSION IF NOT EXISTS citext"
    end

    create_table :cross_channel_digests, id: false, primary_key: :username do |t|
      t.citext :username, null: false, primary_key: true
      t.integer :distinct_channels_24h, null: false
      t.datetime :refreshed_at, null: false
    end

    add_index :cross_channel_digests, :refreshed_at, name: "idx_cross_channel_digests_refreshed_at"
  end

  def down
    drop_table :cross_channel_digests
  end
end
