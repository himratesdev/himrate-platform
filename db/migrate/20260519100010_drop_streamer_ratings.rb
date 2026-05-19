# frozen_string_literal: true

# TASK-201 Phase 3.2: drop streamer_ratings table.
# All Rails callers removed in Phase 2.2 (StreamerRating model + StreamerRatingRefreshWorker
# + factory + spec + Channel#has_one :streamer_rating + Trust::ShowService field & methods
# + PostStreamWorker enqueue). Phase 3.1 DV 🟢 confirmed runtime GONE on staging since
# 2026-05-17 (38+ hours uptime with 0 NameError / UndefinedTable hits in Loki).
#
# External FKs INTO streamer_ratings = 0 (verified via db/structure.sql sweep).
# FK FROM streamer_ratings (channel_id → channels.id) auto-dropped with table.
#
# Reverses (consolidated final shape):
#   - 20260328100001_create_streamer_ratings.rb       (8 base columns + unique concurrent index)
#   - 20260416100001_add_confidence_and_observed_to_streamer_ratings.rb (+2 columns)
#
# def down rebuilds the final schema in a SINGLE create_table так, чтобы produced
# pg_dump byte-identical с pre-drop db/structure.sql. The project's structure.sql
# emits columns alphabetically after the primary key (id), so create_table block
# uses explicit t.datetime для timestamps вместо t.timestamps shortcut — это
# позволяет interleave created_at / updated_at в alphabetical order между другими
# columns (otherwise t.timestamps would emit оба в конце, drifting from canonical).
#
# Uses disable_ddl_transaction! to match original concurrent index creation pattern
# (20260328100001 also used disable_ddl_transaction! + algorithm: :concurrently).

class DropStreamerRatings < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    drop_table :streamer_ratings, if_exists: true
  end

  def down
    create_table :streamer_ratings, id: :uuid do |t|
      t.datetime :calculated_at, null: false
      t.references :channel, type: :uuid, null: false, foreign_key: true, index: false
      t.string :confidence_level, limit: 20
      t.datetime :created_at, null: false
      t.decimal :decay_lambda, precision: 5, scale: 4, null: false, default: 0.05
      t.decimal :rating_observed, precision: 5, scale: 2
      t.decimal :rating_score, precision: 5, scale: 2, null: false
      t.integer :streams_count, null: false, default: 0
      t.datetime :updated_at, null: false
    end

    add_index :streamer_ratings, :channel_id, unique: true,
      algorithm: :concurrently, if_not_exists: true
  end
end
