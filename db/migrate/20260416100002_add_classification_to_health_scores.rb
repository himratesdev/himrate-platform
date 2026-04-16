# frozen_string_literal: true

# TASK-037 FR-027: Store HS classification in DB for percentile queries.
class AddClassificationToHealthScores < ActiveRecord::Migration[8.0]
  def change
    add_column :health_scores, :hs_classification, :string, limit: 20
  end
end
