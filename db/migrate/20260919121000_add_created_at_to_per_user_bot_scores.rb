# frozen_string_literal: true

# DETECTION-AUDIT 2026-09-19 (PIPELINE-HEALTH #12). per_user_bot_scores — 9.53M rows, the output of
# one of the live detection stages — carries no time column at all, so «is bot scoring still
# running?» could only be answered by joining every row back to streams.started_at. A stage whose
# freshness cannot be read cannot be alarmed on; the audit had to reason about it indirectly.
#
# NEW rows only. The default is attached AFTER the column exists, so the 9.5M existing rows keep
# NULL — honestly unknown (they predate the column; their true insert time is unrecoverable), never
# a fabricated timestamp. No backfill for the same reason.
#
# No index on purpose: the operator query is MAX(created_at) / a recent-window count, run by a human
# or a monitor, against a table on the hot upsert path of every scored stream. An index would tax
# every write for a query nobody runs in a loop. Add one when a real consumer needs it.
class AddCreatedAtToPerUserBotScores < ActiveRecord::Migration[8.0]
  def up
    add_column :per_user_bot_scores, :created_at, :datetime, if_not_exists: true
    # Belt for any writer that bypasses ActiveRecord's timestamp injection (raw SQL / COPY).
    change_column_default :per_user_bot_scores, :created_at, from: nil, to: -> { "CURRENT_TIMESTAMP" }
  end

  def down
    remove_column :per_user_bot_scores, :created_at, if_exists: true
  end
end
