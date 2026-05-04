# frozen_string_literal: true

# TASK-085 FR-020 (ADR-085 D-8a): add interrupted_at column to streams.
# Set when StreamOfflineWorker detects ungraceful end (no CCV update >10min
# AND no graceful EventSub stream.offline). Heuristic detection per ADR.
#
# Nullable — existing streams = NULL = NOT interrupted (default behavior).
# Used by Stream Summary endpoint (data.partial: true) for partial data UX.

class AddInterruptedAtToStreams < ActiveRecord::Migration[8.0]
  def change
    add_column :streams, :interrupted_at, :datetime, null: true
  end
end
