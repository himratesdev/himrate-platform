# frozen_string_literal: true

# TASK-201 Phase 3.1: drop health_scores table.
# All Rails callers removed in Phase 2.1-2.5 (HealthScore model + Hs::Engine + HS controllers +
# Channel#has_many + Stream#has_many + serializer enrichment + Pundit policies + workers
# gone). DV verified 0 callers on staging.
#
# def down reconstructs full schema (original CREATE + 3 amendments):
#   - 20260324000007 (original CREATE in create_analytics_tables.rb — 11 base columns)
#   - 20260416100002 (add hs_classification column)
#   - 20260417100004 (add category column + idx_hs_channel_cat_time)
#   - 20260417100011 (data normalization — no schema change; data loss acceptable on rollback,
#     `def down: raise ActiveRecord::IrreversibleMigration` upstream)

class DropHealthScores < ActiveRecord::Migration[8.0]
  def up
    drop_table :health_scores, if_exists: true
  end

  def down
    create_table :health_scores, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :stream, type: :uuid, foreign_key: true
      t.decimal :health_score, precision: 5, scale: 2, null: false
      t.decimal :ti_component, precision: 5, scale: 2
      t.decimal :stability_component, precision: 5, scale: 2
      t.decimal :engagement_component, precision: 5, scale: 2
      t.decimal :growth_component, precision: 5, scale: 2
      t.decimal :consistency_component, precision: 5, scale: 2
      t.string :confidence_level, limit: 20
      t.datetime :calculated_at, null: false
    end

    # Amendment 20260416100002: hs_classification column.
    add_column :health_scores, :hs_classification, :string, limit: 20

    # Amendment 20260417100004: category column + composite index.
    add_column :health_scores, :category, :string, limit: 100
    add_index :health_scores, %i[channel_id category calculated_at],
      name: "idx_hs_channel_cat_time", order: { calculated_at: :desc }
  end
end
