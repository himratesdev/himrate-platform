# frozen_string_literal: true

# TASK-036 FR-018: Remove legacy jsonb column after migration to join table.
class RemoveChannelsListFromWatchlists < ActiveRecord::Migration[8.0]
  def up
    remove_column :watchlists, :channels_list
  end

  def down
    add_column :watchlists, :channels_list, :jsonb, default: [], null: false
  end
end
