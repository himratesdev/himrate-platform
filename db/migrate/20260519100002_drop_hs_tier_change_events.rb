# frozen_string_literal: true

# TASK-201 Phase 3.1: drop hs_tier_change_events table.
# All Rails callers removed in Phase 2.1-2.5 (HsTierChangeEvent model + tier-change
# detector services gone). DV verified 0 callers on staging.
#
# Reverses original CREATE from 20260417100005_create_hs_tier_change_events.rb.

class DropHsTierChangeEvents < ActiveRecord::Migration[8.0]
  def up
    drop_table :hs_tier_change_events, if_exists: true
  end

  def down
    create_table :hs_tier_change_events, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :stream, type: :uuid, foreign_key: true
      t.string :event_type, limit: 30, null: false, default: "tier_change"
      t.string :from_tier, limit: 30
      t.string :to_tier, limit: 30, null: false
      t.decimal :hs_before, precision: 5, scale: 2
      t.decimal :hs_after, precision: 5, scale: 2, null: false
      t.jsonb :metadata, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end

    add_index :hs_tier_change_events, %i[channel_id event_type occurred_at],
      order: { occurred_at: :desc }, name: "idx_hs_tier_events_channel_type_time"
    add_index :hs_tier_change_events, :occurred_at,
      order: { occurred_at: :desc }, name: "idx_hs_tier_events_time"
  end
end
