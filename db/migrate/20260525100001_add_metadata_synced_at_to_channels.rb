# frozen_string_literal: true

# TASK-251.3: track when a channel's Helix metadata (display_name / avatar / broadcaster_type
# / description) was last synced, so ChannelMetadataRefreshWorker can backfill null rows and
# re-sync stale ones at a bounded cadence (channels created by discovery/EventSub carry only
# login + is_monitored → metadata was null).
class AddMetadataSyncedAtToChannels < ActiveRecord::Migration[8.0]
  def change
    # Column only (transactional). The index is built CONCURRENTLY in a separate migration
    # (20260525100002) — channels is large (100k+) and migrations run during rolling deploy
    # while the old release still writes to it (PG blocker fix, repo convention BUG-012).
    add_column :channels, :metadata_synced_at, :datetime
  end
end
