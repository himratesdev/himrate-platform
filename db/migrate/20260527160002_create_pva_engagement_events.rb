# frozen_string_literal: true

# TASK-113 BE-1 (FR-007): client-captured engagement events (M7 log + M9 supporter input).
# Источник = extension content-script наблюдает СВОИ cheer/sub/follow/hype-действия в странице
# (DSV: EventSub broadcaster-scoped → НЕ источник; PO option B = client-capture, go-forward).
# Forward через POST /me/analytics/engagement → EngagementIngestWorker → сюда.
# event_hash = SHA256 idempotency (как SyncEvent FR-023): один и тот же event дважды → один раз.
class CreatePvaEngagementEvents < ActiveRecord::Migration[8.0]
  def up
    create_table :pva_engagement_events, id: :uuid do |t|
      t.references :user, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.uuid :channel_id
      t.string :twitch_login, limit: 50
      t.string :event_type, null: false, limit: 20 # sub / cheer / follow / hype_contribution
      t.integer :amount                              # bits (cheer) / months (sub) — nullable
      t.boolean :anonymous, null: false, default: false
      t.string :source, null: false, limit: 20, default: "client_capture" # client_capture / helix
      t.datetime :occurred_at, null: false
      t.string :event_hash, null: false, limit: 64
      t.timestamps
    end

    add_index :pva_engagement_events, %i[user_id event_hash], unique: true,
      name: "idx_pva_engagement_dedupe"
    add_index :pva_engagement_events, %i[user_id occurred_at], name: "idx_pva_engagement_user_time"
    add_index :pva_engagement_events, %i[user_id event_type], name: "idx_pva_engagement_user_type"
  end

  def down
    drop_table :pva_engagement_events
  end
end
