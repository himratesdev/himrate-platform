# frozen_string_literal: true

# T1-074 PR3b — recreate the latest_tih_per_stream MV with TI v2 columns (pulls forward the MV half
# of the M2 follow-up deferred by 20260718120000; the legacy TIH column DROP stays deferred).
# ALTER MV cannot add columns → DROP/CREATE. v1 columns kept as a bridge (mixed windows persist for
# the full TIH retention; StreamerReputationRefreshWorker uses a dual predicate). Retired
# classification/cold_start_status are dropped from the MV — zero code consumers (grounded sweep
# 2026-07-20). CREATE takes a brief lock on the TIH source; consumers are Sidekiq-side (retry 3
# absorbs the unreadability window). The UNIQUE index is REQUIRED by REFRESH CONCURRENTLY
# (trends/latest_tih_refresh_worker).
class RecreateLatestTihPerStreamMvForTiV2 < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  NEW_SQL = <<~SQL.squish
    CREATE MATERIALIZED VIEW latest_tih_per_stream AS
    SELECT DISTINCT ON (t.stream_id)
      t.stream_id, t.channel_id, t.engine_version,
      t.trust_index_score, t.erv_percent,
      t.authenticity, t.erv, t.erv_lo, t.erv_hi,
      t.band_row, t.band_sub, t.band_color,
      t.reason_codes, t.confirmed_anomaly,
      t.cold_start_tier, t.confidence_marker,
      t.ccv, t.confidence, t.signal_breakdown,
      t.calculated_at, t.id AS trust_index_history_id
    FROM trust_index_histories t
    JOIN streams s ON s.id = t.stream_id
    WHERE s.ended_at IS NOT NULL
    ORDER BY t.stream_id, t.calculated_at DESC, t.id DESC
  SQL

  OLD_SQL = <<~SQL.squish
    CREATE MATERIALIZED VIEW latest_tih_per_stream AS
    SELECT DISTINCT ON (t.stream_id)
      t.stream_id, t.channel_id, t.trust_index_score, t.erv_percent, t.ccv, t.confidence,
      t.classification, t.cold_start_status, t.signal_breakdown, t.calculated_at,
      t.id AS trust_index_history_id
    FROM trust_index_histories t
    JOIN streams s ON s.id = t.stream_id
    WHERE s.ended_at IS NOT NULL
    ORDER BY t.stream_id, t.calculated_at DESC, t.id DESC
  SQL

  def up
    execute("DROP MATERIALIZED VIEW IF EXISTS latest_tih_per_stream")
    execute(NEW_SQL) # WITH DATA by default → populated at migrate time
    execute("CREATE UNIQUE INDEX idx_latest_tih_per_stream_stream_id ON latest_tih_per_stream (stream_id)")
    execute("CREATE INDEX idx_latest_tih_per_stream_channel_id ON latest_tih_per_stream (channel_id)")
  end

  def down
    execute("DROP MATERIALIZED VIEW IF EXISTS latest_tih_per_stream")
    execute(OLD_SQL)
    execute("CREATE UNIQUE INDEX idx_latest_tih_per_stream_stream_id ON latest_tih_per_stream (stream_id)")
    execute("CREATE INDEX idx_latest_tih_per_stream_channel_id ON latest_tih_per_stream (channel_id)")
  end
end
