# frozen_string_literal: true

# TASK-032 CR #12: Real merged parts count instead of hardcoded 2.
# Stores actual number of parts when streams are merged (default 1 = no merge).

class AddMergedPartsCountToStreams < ActiveRecord::Migration[8.1]
  def change
    add_column :streams, :merged_parts_count, :integer, default: 1, null: false
  end
end
