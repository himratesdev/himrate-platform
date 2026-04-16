# frozen_string_literal: true

# TASK-038 FR-030: HS Tier Change Events — extensible schema (BR-25/26/29).
# event_type + metadata jsonb allows future: significant_drop, significant_rise, category_change.
# Permanent retention (Big Data + notifications). Partitioning plan at >5M rows.

class CreateHsTierChangeEvents < ActiveRecord::Migration[8.0]
  def change
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
