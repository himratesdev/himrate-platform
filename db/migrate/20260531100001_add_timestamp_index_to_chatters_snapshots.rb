# frozen_string_literal: true

# 2026-05-31 — Cleanup worker hotfix. CleanupWorker#cleanup_old_records hit 3 consecutive
# `ActiveRecord::QueryCanceled` (PG sqlstate 57014, statement_timeout 30s) on
# chatters_snapshots overnight: each `WHERE timestamp < cutoff LIMIT 1000 ... DELETE`
# was doing a full-table scan because the table has indexes on
# (stream_id) + (stream_id, timestamp) — but NOTHING on `timestamp` alone. With
# 1,036,514 rows / 875 MB and growing ~76/min (StreamMonitorWorker post-PR #231),
# a seq-scan-and-LIMIT can't beat the 30s budget. Each error increments the
# AccessoryDriftDetector consecutive-failure counter; at 3 consecutive errors the
# :cleanup_worker Flipper flag auto-disables (FR-042) → cleanup stops entirely
# → table grows unbounded → other queries on chatters_snapshots get slower too.
#
# Fix: add a plain (timestamp) btree so the cleanup query can do an Index Scan +
# instantly drop the 1000 oldest rows. Sibling tables (ccv_snapshots, ti_signals,
# trust_index_histories, etc.) all already have a (timestamp) or (calculated_at)
# index — chatters_snapshots was the only table missing one.
#
# Per project rule [[feedback_concurrent_index_large_tables]]: on tables with
# 100k+ rows (chatters_snapshots = 1M+), add_index MUST use
# `algorithm: :concurrently` + `disable_ddl_transaction!` so the rolling Kamal
# deploy doesn't take a SHARE-lock that blocks INSERTs. Doing it in a
# standalone migration (column+index migrations split when the column path is
# transactional and the index is not) — there's no column change here, so the
# whole migration just disables the txn.

class AddTimestampIndexToChattersSnapshots < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = :idx_chatters_snapshots_timestamp

  def up
    return if index_exists?(:chatters_snapshots, :timestamp, name: INDEX_NAME)

    add_index :chatters_snapshots, :timestamp,
              name: INDEX_NAME,
              algorithm: :concurrently
  end

  def down
    return unless index_exists?(:chatters_snapshots, :timestamp, name: INDEX_NAME)

    remove_index :chatters_snapshots, name: INDEX_NAME, algorithm: :concurrently
  end
end
