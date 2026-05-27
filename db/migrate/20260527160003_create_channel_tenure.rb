# frozen_string_literal: true

# TASK-113 BE-1 (FR-008, M8 свёрнут в M9): точный sub-tenure зрителя по каналу.
# Источник = IRC badge-info (client-side, свои бейджи в чатах) — точные месяцы, НЕ capped 12/24/36.
# Питает M9 supporter-карты («Sub 21 мес») + composite-score.
class CreateChannelTenure < ActiveRecord::Migration[8.0]
  def up
    create_table :channel_tenure, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      # channel_id/twitch_login = денормализ. Twitch-канал, БЕЗ FK на channels (client-capture
      # на произвольных каналах — CR Nit-1/Nit-2, rationale в миграции 160001). twitch_login зеркалит channels.login.
      t.uuid :channel_id, null: false
      t.string :twitch_login, limit: 50
      t.integer :sub_tier      # 1 / 2 / 3 — nullable (follow без sub)
      t.integer :months, null: false, default: 0
      t.integer :streak, null: false, default: 0
      t.date :anniversary_at
      t.datetime :observed_at, null: false
      t.timestamps
    end

    add_index :channel_tenure, %i[user_id channel_id], unique: true, name: "idx_channel_tenure_unique"
  end

  def down
    drop_table :channel_tenure
  end
end
