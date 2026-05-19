# frozen_string_literal: true

# TASK-201 Phase 3.1: drop rehabilitation_penalty_events table.
# All Rails callers removed in Phase 2.1-2.5 (RehabilitationPenaltyEvent model +
# RehabilitationTracker + BonusAcceleratorCalculator + PenaltyEventEmitter services
# gone). DV verified 0 callers on staging.
#
# Reverses original CREATE from 20260417100008_create_rehabilitation_penalty_events.rb.

class DropRehabilitationPenaltyEvents < ActiveRecord::Migration[8.0]
  def up
    drop_table :rehabilitation_penalty_events, if_exists: true
  end

  def down
    create_table :rehabilitation_penalty_events, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true
      t.references :applied_stream, type: :uuid, foreign_key: { to_table: :streams }
      t.decimal :initial_penalty, precision: 5, scale: 2, null: false
      t.integer :required_clean_streams, null: false, default: 15
      t.integer :clean_streams_at_resolve
      t.datetime :applied_at, null: false
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :rehabilitation_penalty_events, %i[channel_id applied_at],
      order: { applied_at: :desc }, name: "idx_rehab_events_channel_time"
    add_index :rehabilitation_penalty_events, :channel_id,
      where: "resolved_at IS NULL", name: "idx_rehab_events_active"
  end
end
