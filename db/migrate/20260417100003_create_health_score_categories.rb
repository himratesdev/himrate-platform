# frozen_string_literal: true

# TASK-038 AR-10: Categories as DB-driven entities (not hardcoded).
# Admin-editable post-launch. Aliases for Twitch game_name variants.

class CreateHealthScoreCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :health_score_categories, id: :uuid do |t|
      t.string :key, limit: 100, null: false
      t.string :display_name, limit: 100, null: false
      t.boolean :is_default, default: false, null: false
      t.timestamps
    end
    add_index :health_score_categories, :key, unique: true
    add_index :health_score_categories, :is_default, unique: true, where: "is_default = true",
      name: "idx_hs_categories_single_default"

    create_table :health_score_category_aliases, id: :uuid do |t|
      t.references :health_score_category, type: :uuid, null: false, foreign_key: true,
        index: { name: "idx_hs_cat_aliases_category" }
      t.string :game_name_alias, limit: 200, null: false
      t.timestamps
    end
    add_index :health_score_category_aliases, :game_name_alias, unique: true,
      name: "idx_hs_cat_aliases_name"
  end
end
