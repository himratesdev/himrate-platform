# frozen_string_literal: true

# TASK-086 (CR Should-5): composite index on trust_index_histories
# (stream_id, calculated_at DESC, id DESC).
#
# Both the daily TIH cleanup —
#   ROW_NUMBER() OVER (PARTITION BY t.stream_id ORDER BY t.calculated_at DESC, t.id DESC)
# — and the latest_tih_per_stream MV definition —
#   SELECT DISTINCT ON (t.stream_id) ... ORDER BY t.stream_id, t.calculated_at DESC, t.id DESC
# — partition/sort trust_index_histories by exactly this key. The pre-existing
# single-column index_trust_index_histories_on_stream_id forces a per-stream-group
# sort. On the biggest table in the system (~660M rows/yr, SRS §11.3) that sort is
# the dominant cost — this matching index turns it into an ordered index scan
# (no Sort node above the Index Scan in the plan).
#
# trust_index_histories is a plain (non-partitioned) table — same as the existing
# idx_tih_channel_calc_at — so CONCURRENTLY applies cleanly. CONCURRENTLY →
# non-blocking build, requires disable_ddl_transaction!. if_not_exists keeps it
# idempotent on a half-applied re-run.

class AddTrustIndexHistoriesStreamCalculatedIdIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :trust_index_histories, %i[stream_id calculated_at id],
      name: "idx_tih_stream_calculated_id",
      order: { calculated_at: :desc, id: :desc },
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :trust_index_histories, name: "idx_tih_stream_calculated_id", algorithm: :concurrently, if_exists: true
  end
end
