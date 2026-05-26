# frozen_string_literal: true

# TASK-251.W2a: index for FollowerSnapshotWorker's "never-snapshotted first" selection
# (WHERE followers_synced_at IS NULL OR < stale; ORDER BY followers_synced_at ASC NULLS FIRST).
# PARTIAL on `is_monitored = true AND deleted_at IS NULL` — the worker only ever scans
# Channel.monitored.active, so the index covers exactly that subset (smaller/faster at 100k+
# rows than a full index; the prune index in TASK-251.2 follows the same partial pattern).
# Built CONCURRENTLY: `channels` is large and migrations run during a rolling Kamal deploy while
# the previous release still writes to it (EventSub online/offline, discovery) — a plain
# CREATE INDEX would take a write-blocking SHARE lock (BUG-012 repo convention).
class AddFollowersSyncedAtIndexToChannels < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :channels, :followers_synced_at,
              order: { followers_synced_at: "ASC NULLS FIRST" },
              where: "is_monitored = true AND deleted_at IS NULL",
              name: "index_channels_on_followers_synced_at",
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :channels, name: "index_channels_on_followers_synced_at",
                 algorithm: :concurrently, if_exists: true
  end
end
