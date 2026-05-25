# frozen_string_literal: true

# TASK-251.3: index for ChannelMetadataRefreshWorker's "never-synced first" backfill
# (WHERE metadata_synced_at IS NULL OR < stale; ORDER BY metadata_synced_at ASC NULLS FIRST).
# Built CONCURRENTLY: `channels` is a large table (100k+) and migrations run during a rolling
# Kamal deploy while the previous release still writes to it (EventSub online/offline,
# ChannelDiscoveryWorker, StreamOnlineWorker) — a plain CREATE INDEX would take a write-
# blocking SHARE lock. Matches the repo convention (BUG-012 CR N-2: channels.login index +
# trust_index_histories index are also concurrent).
class AddMetadataSyncedAtIndexToChannels < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :channels, :metadata_synced_at,
              order: { metadata_synced_at: "ASC NULLS FIRST" },
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :channels, name: "index_channels_on_metadata_synced_at",
                 algorithm: :concurrently, if_exists: true
  end
end
