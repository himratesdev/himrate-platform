# frozen_string_literal: true

# TASK-038 FR-031: HealthScore.category column for tier/category change detection.
# Backfilled from streams.game_name on the latest stream.

class AddCategoryToHealthScores < ActiveRecord::Migration[8.0]
  def change
    add_column :health_scores, :category, :string, limit: 100
    add_index :health_scores, %i[channel_id category calculated_at],
      name: "idx_hs_channel_cat_time", order: { calculated_at: :desc }

    # Backfill happens in M11 (normalize via CategoryMapper) to ensure consistency
    # with new rows written by worker using normalized keys.
  end
end
