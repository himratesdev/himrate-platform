# frozen_string_literal: true

# V1-RETIRE (2026-09-02, PO-approved): the v1 verdict engine is fully removed from the codebase —
# this migration retires its data footprint in trust_index_histories:
#   1. DELETE the residual v1 rows (~28.6k / 38 MB on prod — junk from the Aug-26..31 flag-lost
#      window after the HOSTKEY loss; zero analytical value, all live data is v2).
#   2. DROP the v1-only scalar columns (retired wire fields; every reader is v2-only now).
#      signal_breakdown STAYS — v2 owns the column for the planned L0/L2 per-signal trace.
#   3. Recreate the latest_tih_per_stream MV without the v1 bridge columns (ALTER MV cannot
#      drop columns → DROP/CREATE, same pattern as 20260720190000). CREATE takes a brief lock
#      on the TIH source; consumers are Sidekiq-side (retry 3 absorbs the window). The UNIQUE
#      index is REQUIRED by REFRESH CONCURRENTLY (trends/latest_tih_refresh_worker).
class RetireV1EngineRowsAndColumns < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  V2_SQL = <<~SQL.squish
    CREATE MATERIALIZED VIEW latest_tih_per_stream AS
    SELECT DISTINCT ON (t.stream_id)
      t.stream_id, t.channel_id, t.engine_version,
      t.authenticity, t.erv, t.erv_lo, t.erv_hi,
      t.band_row, t.band_sub, t.band_color,
      t.reason_codes, t.confirmed_anomaly,
      t.cold_start_tier, t.confidence_marker,
      t.ccv, t.signal_breakdown,
      t.calculated_at, t.id AS trust_index_history_id
    FROM trust_index_histories t
    JOIN streams s ON s.id = t.stream_id
    WHERE s.ended_at IS NOT NULL
    ORDER BY t.stream_id, t.calculated_at DESC, t.id DESC
  SQL

  def up
    # Batched delete — bounded row count, but stay gentle on the live box.
    loop do
      deleted = execute(
        "DELETE FROM trust_index_histories WHERE id IN " \
        "(SELECT id FROM trust_index_histories WHERE engine_version = 'v1' LIMIT 10000)"
      ).cmd_tuples
      break if deleted.zero?
    end

    execute("DROP MATERIALIZED VIEW IF EXISTS latest_tih_per_stream")

    # The column default was 'v1' — a bare INSERT would mint an invisible-to-readers row.
    change_column_default :trust_index_histories, :engine_version, from: "v1", to: "v2"

    remove_column :trust_index_histories, :trust_index_score, if_exists: true
    remove_column :trust_index_histories, :erv_percent, if_exists: true
    remove_column :trust_index_histories, :classification, if_exists: true
    remove_column :trust_index_histories, :cold_start_status, if_exists: true
    remove_column :trust_index_histories, :confidence, if_exists: true

    execute(V2_SQL) # WITH DATA by default → populated at migrate time
    execute("CREATE UNIQUE INDEX idx_latest_tih_per_stream_stream_id ON latest_tih_per_stream (stream_id)")
    execute("CREATE INDEX idx_latest_tih_per_stream_channel_id ON latest_tih_per_stream (channel_id)")
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "v1 rows are deleted and the engine code is gone"
  end
end
