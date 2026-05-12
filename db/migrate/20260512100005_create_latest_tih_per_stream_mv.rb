# frozen_string_literal: true

# TASK-086 FR-032 (ADR-086 §4.2): materialized view — 1 row per ended stream
# holding that stream's FINAL TIH. Speeds up BestWorstStreamFinder /
# StreamerReputation.pattern_history queries (they only need per-stream final TIH,
# not the full intermediate history that CleanupWorker prunes).
#
# Column names = the ACTUAL trust_index_histories schema (`trust_index_score`,
# `erv_percent`, `signal_breakdown`, `ccv`) — NOT the SRS draft's `ti_score`/`erv`/
# `signals_data` (ADR-086 §4.8 — terminology drift in SRS, fixed here).
#
# UNIQUE INDEX on stream_id is REQUIRED for `REFRESH MATERIALIZED VIEW CONCURRENTLY`
# (PostgreSQL constraint). Refresh is async via Trends::LatestTihRefreshWorker
# (enqueued from PostStreamWorker, advisory-lock dedup) — not a DB trigger.
#
# CREATE MATERIALIZED VIEW is NOT CONCURRENTLY-capable → it takes a brief lock on
# the source table. On the first launch TIH is empty → instant. On an established
# DB it's a phased low-traffic deploy step (SRS §12). disable_ddl_transaction!
# because CREATE INDEX afterwards is fine either way and matches the pattern.

class CreateLatestTihPerStreamMv < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    execute(<<~SQL.squish)
      CREATE MATERIALIZED VIEW latest_tih_per_stream AS
      SELECT DISTINCT ON (t.stream_id)
        t.stream_id,
        t.channel_id,
        t.trust_index_score,
        t.erv_percent,
        t.ccv,
        t.confidence,
        t.classification,
        t.cold_start_status,
        t.signal_breakdown,
        t.calculated_at,
        t.id AS trust_index_history_id
      FROM trust_index_histories t
      JOIN streams s ON s.id = t.stream_id
      WHERE s.ended_at IS NOT NULL
      ORDER BY t.stream_id, t.calculated_at DESC, t.id DESC
    SQL

    execute("CREATE UNIQUE INDEX idx_latest_tih_per_stream_stream_id ON latest_tih_per_stream (stream_id)")
    execute("CREATE INDEX idx_latest_tih_per_stream_channel_id ON latest_tih_per_stream (channel_id)")
  end

  def down
    execute("DROP MATERIALIZED VIEW IF EXISTS latest_tih_per_stream")
  end
end
