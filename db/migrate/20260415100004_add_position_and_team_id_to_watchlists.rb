# frozen_string_literal: true

# TASK-036 FR-025: Position for user ordering. FR-027: team_id foundation for Business sharing.
class AddPositionAndTeamIdToWatchlists < ActiveRecord::Migration[8.0]
  def change
    add_column :watchlists, :position, :integer
    add_column :watchlists, :team_id, :uuid

    add_index :watchlists, :team_id, name: "idx_watchlists_team_id"
    add_foreign_key :watchlists, :users, column: :team_id, on_delete: :nullify
  end
end
