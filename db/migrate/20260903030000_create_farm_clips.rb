# frozen_string_literal: true

# EPIC FARM T-F2: category-wide clip pool + view snapshots (real view_velocity source).
# Separate Farm:: domain — NOT part of the bot-detection tables.
class CreateFarmClips < ActiveRecord::Migration[8.0]
  def change
    create_table :farm_clips, id: :uuid do |t|
      t.string :clip_id, null: false
      t.string :game_id, null: false
      t.string :broadcaster_twitch_id, null: false
      t.string :broadcaster_name
      t.string :creator_twitch_id
      t.string :creator_name
      t.string :title
      t.string :language
      t.string :url
      t.string :video_id
      t.string :thumbnail_url
      t.integer :view_count, null: false, default: 0
      t.float :duration
      t.integer :vod_offset
      t.boolean :is_featured, null: false, default: false
      t.datetime :twitch_created_at, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :farm_clips, :clip_id, unique: true
    add_index :farm_clips, [ :game_id, :twitch_created_at ]
    add_index :farm_clips, :broadcaster_twitch_id

    create_table :farm_clip_view_snapshots, id: :uuid do |t|
      t.references :farm_clip, null: false, foreign_key: true, type: :uuid
      t.integer :view_count, null: false
      t.datetime :captured_at, null: false
      t.timestamps
    end
    add_index :farm_clip_view_snapshots, [ :farm_clip_id, :captured_at ]
  end
end
