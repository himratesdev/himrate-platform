# frozen_string_literal: true

# TASK-113 BE-1 (FR-008, M9 «Моё место у каналов»): per-channel КАТЕГОРИАЛЬНЫЙ статус сапортёра.
# Real-data reroll (DSV/QDC): АБСОЛЮТНЫЕ пороги по СВОИМ метрикам (НЕ percentile-vs-others,
# НЕ числовой публичный скор — BR-006). composite_score = internal (не показывается в UI),
# только для маппинга в tier. SupporterStatusWorker пересчитывает (weekly).
# Формула (ADR OQ-1, tunable): tenure_mo*2 + cheers_usd + hype_count*3 + watch_consistency*0.5
#   → >=40 devoted / >=20 loyal / >=8 regular / >0 active.
class CreatePvaSupporterStatus < ActiveRecord::Migration[8.0]
  TIERS = %w[devoted loyal regular active].freeze

  def up
    create_table :pva_supporter_status, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      # channel_id/twitch_login = денормализ. Twitch-канал, БЕЗ FK на channels (client-capture
      # на произвольных каналах — CR Nit-1/Nit-2, rationale в миграции 160001). twitch_login зеркалит channels.login.
      t.uuid :channel_id, null: false
      t.string :twitch_login, limit: 50
      t.string :tier, null: false, limit: 12 # devoted / loyal / regular / active
      t.decimal :composite_score, precision: 8, scale: 2 # internal, не в UI
      t.datetime :computed_at, null: false
      t.timestamps
    end

    add_index :pva_supporter_status, %i[user_id channel_id], unique: true,
      name: "idx_pva_supporter_unique"
    add_check_constraint :pva_supporter_status,
      "tier IN ('devoted','loyal','regular','active')", name: "chk_pva_supporter_tier"
  end

  def down
    drop_table :pva_supporter_status
  end
end
