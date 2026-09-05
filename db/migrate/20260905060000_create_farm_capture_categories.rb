# frozen_string_literal: true

# EPIC FARM T-F1: the farm's category-join capture set is configured per Twitch category
# (game_id). One row = one category the capture pool joins wholesale (all live channels,
# optional language allowlist, optional viewer floor). Separate Farm:: domain — NOT part of
# the bot-detection `channels` set (no Channel/Stream rows, no EventSub, no TI).
class CreateFarmCaptureCategories < ActiveRecord::Migration[8.0]
  def change
    create_table :farm_capture_categories, id: :uuid do |t|
      t.string :game_id, null: false            # Twitch category id, strict (never name matching)
      t.string :game_name, null: false          # human label for logs / ops
      t.string :languages, array: true          # Helix `language` allowlist; NULL = all languages
      t.boolean :enabled, null: false, default: true
      t.integer :viewer_floor, null: false, default: 0 # 0 = no floor (smurfs are the farm's wild-cards)
      t.timestamps
    end
    add_index :farm_capture_categories, :game_id, unique: true
  end
end
