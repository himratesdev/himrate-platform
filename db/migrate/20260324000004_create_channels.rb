# frozen_string_literal: true

class CreateChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :channels, id: :uuid do |t|
      t.string :twitch_id, limit: 50, null: false
      t.string :login, limit: 255, null: false
      t.string :display_name, limit: 255
      t.string :broadcaster_type, limit: 20
      t.integer :followers_total, default: 0
      t.text :description
      t.text :profile_image_url
      t.boolean :is_monitored, null: false, default: false
      t.datetime :deleted_at

      t.timestamps
    end

    add_index :channels, :twitch_id, unique: true
    add_index :channels, :login
    add_index :channels, :is_monitored
    add_index :channels, :deleted_at
  end
end
