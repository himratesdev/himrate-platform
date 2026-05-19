# frozen_string_literal: true

# TASK-201 Phase 3.1: drop health_score_tiers table.
# All Rails callers removed in Phase 2.1-2.5 (HealthScoreTier model + tier-palette
# services gone). DV verified 0 callers on staging.
#
# Reverses original CREATE from 20260417100007_create_health_score_tiers.rb.

class DropHealthScoreTiers < ActiveRecord::Migration[8.0]
  def up
    drop_table :health_score_tiers, if_exists: true
  end

  def down
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
