# frozen_string_literal: true

# TASK-201 Phase 3.1: drop health_score_category_aliases table.
# MUST drop BEFORE health_score_categories (FK dependency: category_aliases.health_score_category_id
# REFERENCES health_score_categories.id).
#
# All Rails callers removed in Phase 2.1-2.5 (HealthScoreCategoryAlias model +
# Hs::CategoryMapper service gone). DV verified 0 callers on staging.
#
# Reverses aliases-block of original CREATE from
# 20260417100003_create_health_score_categories.rb (categories + aliases в одной migration).

class DropHealthScoreCategoryAliases < ActiveRecord::Migration[8.0]
  def up
    drop_table :health_score_category_aliases, if_exists: true
  end

  def down
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
