# frozen_string_literal: true

# BUG-C PR-C2: fair rotation for live per-user bot scoring. LiveBotScoringWorker was ordered
# oldest-started-first and capped at MAX_STREAMS_PER_RUN=300 — at >300 concurrent live streams
# (the 1000-10000-channel scale target) the newest streams were starved (never scored), and a
# zombie (un-closed ended_at) stream permanently topped the queue. `bot_scored_at` lets the worker
# rotate by least-recently-scored (ASC NULLS FIRST → never-scored young streams get priority).
class AddBotScoredAtToStreams < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_column :streams, :bot_scored_at, :datetime, if_not_exists: true
    # Partial (active only) — mirrors idx_streams_active_started_at. Serves the rotation ORDER BY
    # over the live set without scanning ended streams.
    add_index :streams, :bot_scored_at, where: "ended_at IS NULL", algorithm: :concurrently,
              if_not_exists: true, name: "idx_streams_active_bot_scored_at"
  end
end
