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
  def up
    remove_column :streams, :peak_ccv
    remove_column :streams, :avg_ccv
    remove_column :streams, :duration_ms
  end

  def down
    add_column :streams, :peak_ccv, :integer, default: 0, null: false
    add_column :streams, :avg_ccv, :integer
    add_column :streams, :duration_ms, :bigint
  end
end
