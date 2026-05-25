# frozen_string_literal: true

# TASK-251.8: partial index over ACTIVE (live) streams ordered by started_at, supporting
# LiveBotScoringWorker's every-10-min query `Stream.active.order(:started_at).limit(N)`. The existing
# idx_streams_ended_at_partial covers the OPPOSITE set (ended_at IS NOT NULL); this symmetric index
# turns the cron query into a bounded range-scan at 100k+ streams instead of a table scan.
# Concurrent + explicit up/down per repo convention (BUG-012).
class AddActiveStartedAtIndexToStreams < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_index :streams, :started_at,
              where: "ended_at IS NULL",
              name: "idx_streams_active_started_at",
              algorithm: :concurrently,
              if_not_exists: true
  end

  def down
    remove_index :streams, name: "idx_streams_active_started_at", algorithm: :concurrently, if_exists: true
  end
end
