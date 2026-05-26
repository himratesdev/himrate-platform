# frozen_string_literal: true

# TASK-251.W2a: index for FollowerSnapshotWorker's "never-snapshotted first" selection
# (WHERE followers_synced_at IS NULL OR < stale; ORDER BY followers_synced_at ASC NULLS FIRST).
# Built CONCURRENTLY: `channels` is large (100k+) and migrations run during a rolling Kamal
# deploy while the previous release still writes to it (EventSub online/offline, discovery) —
# a plain CREATE INDEX would take a write-blocking SHARE lock. Matches repo convention
# (BUG-012; mirrors the metadata_synced_at index in TASK-251.3).
class AddFollowersSyncedAtIndexToChannels < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :channels, :followers_synced_at,
              order: { followers_synced_at: "ASC NULLS FIRST" },
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :channels, name: "index_channels_on_followers_synced_at",
                 algorithm: :concurrently, if_exists: true
  end
end
