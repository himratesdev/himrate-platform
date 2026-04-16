# frozen_string_literal: true

# TASK-038 FR-031: HealthScore.category column for tier/category change detection.
# Backfilled from streams.game_name on the latest stream.

class AddCategoryToHealthScores < ActiveRecord::Migration[8.0]
  def up
    add_column :health_scores, :category, :string, limit: 100
    add_index :health_scores, %i[channel_id category calculated_at],
      name: "idx_hs_channel_cat_time", order: { calculated_at: :desc }

    # Backfill from stream.game_name
    execute <<~SQL
      UPDATE health_scores hs
      SET category = s.game_name
      FROM streams s
      WHERE hs.stream_id = s.id AND hs.category IS NULL;
    SQL
  end

  def down
    remove_index :health_scores, name: "idx_hs_channel_cat_time"
    remove_column :health_scores, :category
  end
end
