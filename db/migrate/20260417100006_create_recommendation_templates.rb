# frozen_string_literal: true

# TASK-038 AR-07: Recommendation templates metadata in DB (not hardcoded).
# Conditions remain as Ruby lambdas (eval of DB strings = security risk).
# Metadata (i18n_key, expected_impact, cta_action, enabled) — DB-editable post-launch.

class CreateRecommendationTemplates < ActiveRecord::Migration[8.0]
  def change
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
