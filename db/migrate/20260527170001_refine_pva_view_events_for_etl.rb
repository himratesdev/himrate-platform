# frozen_string_literal: true

# TASK-113 BE-2 (FR-001..005): refine pva_view_events под РЕАЛЬНЫЙ SyncEvent stream_view payload + idempotent ETL.
# Payload (spec/factories/sync_events.rb): { channel_id: "<twitch numeric id>", watched_at, duration_sec }.
# - twitch_channel_id = СТАБИЛЬНЫЙ ключ канала (Twitch numeric id из payload, ВСЕГДА есть).
#   channel_id(uuid)/twitch_login = enrichment — резолвятся ТОЛЬКО если канал в нашем `channels`
#   (зритель смотрит ПРОИЗВОЛЬНЫЕ каналы, многих нет в curated channels — BE-1 Nit-2 rationale).
# - source_event_hash = SyncEvent.event_hash источника → exactly-once ETL (re-run safe, out-of-order safe).
#   UNIQUE обязан включать partition key started_at (требование native partitioning, как PK (id, started_at)).
#
# Таблица пуста (BE-1 задеплоена только что, 0 строк, нет консьюмеров) → add_column NOT NULL + add_index
# мгновенны и безопасны при rolling deploy (НЕ large-table write-blocking SHARE-lock сценарий — поэтому
# не нужен algorithm: :concurrently; см. feedback_concurrent_index_large_tables = про pre-existing large).
class RefinePvaViewEventsForEtl < ActiveRecord::Migration[8.0]
  def up
    add_column :pva_view_events, :twitch_channel_id, :string, limit: 30, null: false
    add_column :pva_view_events, :source_event_hash, :string, limit: 64, null: false

    add_index :pva_view_events, %i[user_id source_event_hash started_at], unique: true,
      name: "idx_pva_view_source_dedupe"
    add_index :pva_view_events, %i[user_id twitch_channel_id], name: "idx_pva_view_user_twitch_channel"
  end

  def down
    remove_index :pva_view_events, name: "idx_pva_view_user_twitch_channel"
    remove_index :pva_view_events, name: "idx_pva_view_source_dedupe"
    remove_column :pva_view_events, :source_event_hash
    remove_column :pva_view_events, :twitch_channel_id
  end
end
