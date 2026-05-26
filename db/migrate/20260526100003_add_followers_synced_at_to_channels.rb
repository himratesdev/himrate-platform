# frozen_string_literal: true

# TASK-251.W2a: track when a channel's follower count was last snapshotted, so
# FollowerSnapshotWorker can backfill never-snapshotted monitored channels and refresh stale
# ones at a bounded daily cadence. FollowerSnapshot feeds Streamer Reputation Growth (#12) +
# Follower Quality (#13), which were dead — no production worker ever wrote a snapshot.
class AddFollowersSyncedAtToChannels < ActiveRecord::Migration[8.0]
  def change
    # Column only (transactional). The index is built CONCURRENTLY in a separate migration
    # (20260526100004) — channels is large (100k+) and migrations run during a rolling deploy
    # while the old release still writes to it (PG blocker fix, repo convention BUG-012).
    add_column :channels, :followers_synced_at, :datetime
  end
end
