# frozen_string_literal: true

# TASK-033 FR-004: Track part boundaries for merged streams.
# Stores TI snapshot at each merge boundary for TI Divergence detection.
class AddPartBoundariesToStreams < ActiveRecord::Migration[8.1]
  def change
    add_column :streams, :part_boundaries, :jsonb, default: [], null: false
  end
end
