# frozen_string_literal: true

# TASK-038 FR-020: Dismissed recommendations — permanent storage (Big Data value).

class CreateDismissedRecommendations < ActiveRecord::Migration[8.0]
  def change
    create_table :dismissed_recommendations, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.string :rule_id, limit: 10, null: false
      t.datetime :dismissed_at, null: false
      t.timestamps
    end

    add_index :dismissed_recommendations, %i[user_id channel_id rule_id],
      unique: true, name: "idx_dismissed_rec_uniq"
  end
end
