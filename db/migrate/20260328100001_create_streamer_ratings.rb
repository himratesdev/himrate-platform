# frozen_string_literal: true

# TASK-017: Streamer Rating — public score (≠ Reputation which is internal input).
# Rating = weighted average TI with exponential decay (λ=0.05).

class CreateStreamerRatings < ActiveRecord::Migration[8.1]
  def up
    create_table :streamer_ratings, id: :uuid do |t|
      t.references :channel, type: :uuid, null: false, foreign_key: true, index: false
      t.decimal :rating_score, precision: 5, scale: 2, null: false
      t.decimal :decay_lambda, precision: 5, scale: 4, null: false, default: 0.05
      t.integer :streams_count, null: false, default: 0
      t.datetime :calculated_at, null: false

      t.timestamps
    end

    add_index :streamer_ratings, :channel_id, unique: true
  end

  def down
    drop_table :streamer_ratings
  end
end
