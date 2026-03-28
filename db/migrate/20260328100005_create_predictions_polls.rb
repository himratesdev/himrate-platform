# frozen_string_literal: true

# TASK-017: Twitch Predictions/Polls aggregate data (Signal #11).

class CreatePredictionsPolls < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    create_table :predictions_polls, id: :uuid do |t|
      t.references :stream, type: :uuid, null: false, foreign_key: true, index: false
      t.string :event_type, limit: 20, null: false
      t.integer :participants_count, null: false
      t.integer :ccv_at_time
      t.decimal :participation_ratio, precision: 5, scale: 4
      t.datetime :timestamp, null: false
    end

    add_index :predictions_polls, %i[stream_id timestamp],
      name: "idx_predictions_polls_stream_time", algorithm: :concurrently, if_not_exists: true
  end

  def down
    drop_table :predictions_polls
  end
end
