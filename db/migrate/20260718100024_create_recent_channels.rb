# frozen_string_literal: true

# LK-BACKEND Wave 1b (screen 01 Home): channels the viewer opened from the ЛК ("Недавно открытые
# каналы"). One row per (user, channel); opened_at bumped on re-open. Distinct from PVA view-events
# (watching a stream) — this tracks opening the channel card in the cabinet.
class CreateRecentChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :recent_channels, id: :uuid do |t|
      t.references :user, type: :uuid, foreign_key: true, null: false
      t.references :channel, type: :uuid, foreign_key: true, null: false
      t.datetime :opened_at, null: false

      t.timestamps
    end

    add_index :recent_channels, %i[user_id channel_id], unique: true
    add_index :recent_channels, %i[user_id opened_at]
  end
end
