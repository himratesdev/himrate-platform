# frozen_string_literal: true

# TASK-086 FR-018 (PO Q13 2026-05-04): partial index on streams.ended_at.
# CleanupWorker#cleanup_old_trust_index_histories filters ended streams via
# `WHERE s.ended_at IS NOT NULL AND s.ended_at < cutoff` — without this index a
# sequential scan on 100k+ streams (build-for-years). Partial index (only rows
# where ended_at IS NOT NULL) keeps it compact (live streams excluded).
#
# CONCURRENTLY → non-blocking build, requires disable_ddl_transaction!.

class AddStreamsEndedAtPartialIndex < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :streams, :ended_at,
      name: "idx_streams_ended_at_partial",
      where: "ended_at IS NOT NULL",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :streams, name: "idx_streams_ended_at_partial", algorithm: :concurrently, if_exists: true
  end
end
