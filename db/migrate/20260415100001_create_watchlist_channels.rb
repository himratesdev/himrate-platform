# frozen_string_literal: true

# TASK-036 FR-018: Join table replacing channels_list jsonb array.
# Proper FK, unique constraint, indexes for efficient querying.
class CreateWatchlistChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :watchlist_channels, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :watchlist_id, null: false
      t.uuid :channel_id, null: false
      t.integer :position
      t.datetime :added_at, null: false, default: -> { "NOW()" }

      t.index :watchlist_id, name: "idx_wc_watchlist"
      t.index :channel_id, name: "idx_wc_channel"
      t.index %i[watchlist_id channel_id], unique: true, name: "idx_wc_watchlist_channel_uniq"
      t.index %i[watchlist_id position], name: "idx_wc_watchlist_position"
    end

    add_foreign_key :watchlist_channels, :watchlists, column: :watchlist_id, on_delete: :cascade
    add_foreign_key :watchlist_channels, :channels, column: :channel_id, on_delete: :cascade
  end
end
