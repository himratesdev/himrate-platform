# frozen_string_literal: true

# TASK-113 BE-3: refine BE-1 engagement-family таблиц под client-capture на ПРОИЗВОЛЬНЫХ каналах.
# twitch_channel_id = СТАБИЛЬНЫЙ ключ канала (Twitch numeric id из payload, ВСЕГДА есть). channel_id(uuid)
# = enrichment (nil для untracked — зритель донатит/чатит на не-трекаемых каналах). Зеркало BE-2
# pva_view_events refine. BE-1 keyed по channel_id(uuid): (а) NOT NULL ломается для untracked,
# (б) nullable channel_id в UNIQUE = dup-баг. Таблицы пусты (flag pva OFF) → add NOT NULL + reindex безопасно.
# pva_engagement_events: дедуп по event_hash (не меняем); twitch_channel_id = grouping-ключ для M9 supporter.
# channel_tenure / pva_supporter_status: per-(user, channel) → unique переезжает на twitch_channel_id,
# channel_id становится nullable enrichment.
class RefineEngagementFamilyForClientCapture < ActiveRecord::Migration[8.0]
  def up
    add_column :pva_engagement_events, :twitch_channel_id, :string, limit: 30, null: false
    add_index :pva_engagement_events, %i[user_id twitch_channel_id], name: "idx_pva_engagement_user_channel"

    add_column :channel_tenure, :twitch_channel_id, :string, limit: 30, null: false
    change_column_null :channel_tenure, :channel_id, true
    remove_index :channel_tenure, name: "idx_channel_tenure_unique"
    add_index :channel_tenure, %i[user_id twitch_channel_id], unique: true, name: "idx_channel_tenure_unique"

    add_column :pva_supporter_status, :twitch_channel_id, :string, limit: 30, null: false
    change_column_null :pva_supporter_status, :channel_id, true
    remove_index :pva_supporter_status, name: "idx_pva_supporter_unique"
    add_index :pva_supporter_status, %i[user_id twitch_channel_id], unique: true, name: "idx_pva_supporter_unique"
  end

  def down
    remove_index :pva_supporter_status, name: "idx_pva_supporter_unique"
    add_index :pva_supporter_status, %i[user_id channel_id], unique: true, name: "idx_pva_supporter_unique"
    change_column_null :pva_supporter_status, :channel_id, false
    remove_column :pva_supporter_status, :twitch_channel_id

    remove_index :channel_tenure, name: "idx_channel_tenure_unique"
    add_index :channel_tenure, %i[user_id channel_id], unique: true, name: "idx_channel_tenure_unique"
    change_column_null :channel_tenure, :channel_id, false
    remove_column :channel_tenure, :twitch_channel_id

    remove_index :pva_engagement_events, name: "idx_pva_engagement_user_channel"
    remove_column :pva_engagement_events, :twitch_channel_id
  end
end
