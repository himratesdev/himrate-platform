# frozen_string_literal: true

# TASK-038 AR-08: HS tier palette in DB (not hardcoded).
# Design team can update colors/labels without deploy.

class CreateHealthScoreTiers < ActiveRecord::Migration[8.0]
  def change
    create_table :health_score_tiers, id: :uuid do |t|
      t.string :key, limit: 20, null: false
      t.integer :min_score, null: false
      t.integer :max_score, null: false
      t.string :color_name, limit: 20, null: false
      t.string :bg_hex, limit: 7, null: false
      t.string :text_hex, limit: 7, null: false
      t.string :i18n_key, limit: 50, null: false
      t.integer :display_order, null: false
      t.timestamps
    end

    add_index :health_score_tiers, :key, unique: true
    add_index :health_score_tiers, :display_order, unique: true
  end
end
