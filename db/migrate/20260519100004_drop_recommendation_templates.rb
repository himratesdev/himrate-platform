# frozen_string_literal: true

# TASK-201 Phase 3.1: drop recommendation_templates table.
# All Rails callers removed in Phase 2.1-2.5 (RecommendationTemplate model +
# Hs::RecommendationService + RecommendationRules service gone). DV verified
# 0 callers on staging.
#
# Reverses original CREATE from 20260417100006_create_recommendation_templates.rb.

class DropRecommendationTemplates < ActiveRecord::Migration[8.0]
  def up
    drop_table :recommendation_templates, if_exists: true
  end

  def down
    create_table :recommendation_templates, id: :uuid do |t|
      t.string :rule_id, limit: 10, null: false
      t.string :component, limit: 30, null: false
      t.string :priority, limit: 15, null: false
      t.string :i18n_key, limit: 100, null: false
      t.string :expected_impact, limit: 50
      t.string :cta_action, limit: 100
      t.boolean :enabled, default: true, null: false
      t.integer :display_order, null: false, default: 0
      t.timestamps
    end

    add_index :recommendation_templates, :rule_id, unique: true
    add_index :recommendation_templates, :enabled
  end
end
