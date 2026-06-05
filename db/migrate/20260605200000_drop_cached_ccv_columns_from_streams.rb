# frozen_string_literal: true

# PR-A1 (EPIC SCALE ARCHITECTURE Step 2): drop denormalized cache columns
# `peak_ccv`, `avg_ccv`, `duration_ms` from `streams` table.
#
# Root problem (BUG #3 from `_tasks/AUDIT-2026-06-05-NIX/findings.md`):
# These columns were written ONCE by StreamOfflineWorker at stream-end —
# never updated during a live stream. nix at 8.5h live had peak_ccv = 0
# in DB even though `ccv_snapshots.maximum(:ccv_count) = 61,002`.
#
# Architecturally the data already lives in two correct places:
#   - LIVE streams: `ccv_snapshots` (rolling samples, indexed on stream_id)
#   - ENDED streams: `post_stream_reports.ccv_peak / ccv_avg / duration_ms`
#
# `Stream#current_peak_ccv / current_avg_ccv / current_duration_ms` (added in
# this PR) read from those sources, so callers always get a correct value
# without write-amplification on every CCV snapshot insert.
#
# Reversible: `down` recreates the columns with their defaults (`peak_ccv: 0`,
# `avg_ccv: NULL`, `duration_ms: NULL`). If a production rollback is required AND
# historical data must be restored into the columns, run a manual backfill via the
# Rails console:
#
#   Stream.find_each do |s|
#     psr = s.post_stream_report
#     s.update_columns(
#       peak_ccv: psr&.ccv_peak || s.ccv_snapshots.maximum(:ccv_count) || 0,
#       avg_ccv:  psr&.ccv_avg  || s.ccv_snapshots.average(:ccv_count)&.round,
#       duration_ms: psr&.duration_ms || (s.ended_at && ((s.ended_at - s.started_at) * 1000).to_i)
#     )
#   end
#
# Not packaged as a rake task because rollback is expected to be a manual operational
# event — preserving the option without baking a one-shot helper into the codebase.

class DropCachedCcvColumnsFromStreams < ActiveRecord::Migration[8.0]
  # PG iter-1 WARNING-1: collapse three sequential `remove_column` calls into one
  # `ALTER TABLE ... DROP COLUMN ..., DROP COLUMN ..., DROP COLUMN ...` so PG acquires
  # ACCESS EXCLUSIVE on `streams` exactly once. Three separate ALTERs would queue any
  # concurrent reader/writer behind 3 lock cycles; single ALTER drops to one cycle.
  # `streams` is a hot row-source — minimising lock surface matters at scale.
  def up
    execute <<~SQL
      ALTER TABLE streams
        DROP COLUMN peak_ccv,
        DROP COLUMN avg_ccv,
        DROP COLUMN duration_ms
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE streams
        ADD COLUMN peak_ccv integer NOT NULL DEFAULT 0,
        ADD COLUMN avg_ccv integer,
        ADD COLUMN duration_ms bigint
    SQL
  end
end
