# frozen_string_literal: true

# TASK-201 Phase 3.1: drop dismissed_recommendations table.
# All Rails callers removed in Phase 2.1-2.5 (Hs::RecommendationService + controller +
# DismissedRecommendation model gone). DV verified 0 callers on staging.
#
# Reverses original CREATE from 20260417100002_create_dismissed_recommendations.rb.

class DropDismissedRecommendations < ActiveRecord::Migration[8.0]
  def up
    drop_table :dismissed_recommendations, if_exists: true
  end

  def down
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
