# frozen_string_literal: true

# TASK-201 Phase 3.1: drop health_score_categories table.
# Must run AFTER drop_health_score_category_aliases (FK dependency cleared).
#
# All Rails callers removed in Phase 2.1-2.5 (HealthScoreCategory model + Category-driven
# weight loader gone). DV verified 0 callers on staging.
#
# Reverses categories-block of original CREATE from
# 20260417100003_create_health_score_categories.rb (categories + aliases в одной migration).

class DropHealthScoreCategories < ActiveRecord::Migration[8.0]
  def up
    drop_table :health_score_categories, if_exists: true
  end

  def down
    create_table :health_score_categories, id: :uuid do |t|
      t.string :key, limit: 100, null: false
      t.string :display_name, limit: 100, null: false
      t.boolean :is_default, default: false, null: false
      t.timestamps
    end
    add_index :health_score_categories, :key, unique: true
    add_index :health_score_categories, :is_default, unique: true, where: "is_default = true",
      name: "idx_hs_categories_single_default"
  end
end
