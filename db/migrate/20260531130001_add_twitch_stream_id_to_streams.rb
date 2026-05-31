# frozen_string_literal: true

# BUG-251.40 Phase A1 — add Twitch's per-broadcast `stream.id` as a first-class column on streams.
#
# WHY THIS EXISTS:
# Our Stream record's identity was previously derived purely from (channel_id + ended_at IS NULL).
# MonitoredLiveDetectorWorker#open_new_streams skipped any channel that already had an open Stream,
# WITHOUT comparing Twitch's actual broadcast id. The 2026-05-31 staging audit found 521 open
# Streams of which 224 were FUSE (Helix shows different per-broadcast id than the open row's
# implicit "this broadcast" — meaning the channel ended one broadcast overnight, started a new
# one, and our detector kept appending CCV/chat/chatters of the NEW broadcast into the OLD row).
# Top examples: Recrent (24h old Deadlock row receiving today's Counter-Strike data),
# pgl/eslcs/forsen/clix all the same pattern.
#
# WHAT THIS PR ADDS:
# A nullable `twitch_stream_id` String column plus a partial UNIQUE index
# `WHERE twitch_stream_id IS NOT NULL`. Partial UNIQUE because legacy rows (existing 521
# open + tens of thousands of closed historical streams) will be NULL until the operational
# cleanup rake (Phase C) finalizes them. New StreamOnlineWorker calls (Phase A2) will populate
# the column from the Helix/EventSub `stream.id` payload. After Phase A2 ships and Phase C
# runs, every NEW Stream carries an immutable Twitch identity; the detector's
# already_live-skip check (Phase A2 rewrite) compares Helix `id` against this column and
# closes-and-reopens on mismatch.
#
# WHY PARTIAL UNIQUE INDEX vs FULL UNIQUE:
# - We never want two rows with the same non-NULL Twitch broadcast id (would mean we double-
#   inserted on a Helix retry — broken).
# - Legacy data has thousands of NULLs that can never satisfy a full UNIQUE constraint.
# - PG partial index handles this exactly.
#
# CONCURRENT INDEX per [[feedback_concurrent_index_large_tables]]: streams table is large
# (tens of thousands of rows on staging, growing every Twitch online event). add_index with
# `algorithm: :concurrently` + `disable_ddl_transaction!` keeps Kamal rolling deploy from
# blocking writers (StreamOnlineWorker is on the live hot path).

class AddTwitchStreamIdToStreams < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = :idx_streams_twitch_stream_id_unique

  def up
    add_column :streams, :twitch_stream_id, :string unless column_exists?(:streams, :twitch_stream_id)

    return if index_exists?(:streams, :twitch_stream_id, name: INDEX_NAME)

    add_index :streams, :twitch_stream_id,
              where: "twitch_stream_id IS NOT NULL",
              unique: true,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    if index_exists?(:streams, :twitch_stream_id, name: INDEX_NAME)
      remove_index :streams, name: INDEX_NAME, algorithm: :concurrently
    end

    remove_column :streams, :twitch_stream_id if column_exists?(:streams, :twitch_stream_id)
  end
end
