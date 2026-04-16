# frozen_string_literal: true

# TASK-038 AR-11: Explicit rehabilitation penalty state (not derived).
# Emitted when TI crosses below 50. Resolved when 15 clean streams completed.

class CreateRehabilitationPenaltyEvents < ActiveRecord::Migration[8.0]
  def change
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
