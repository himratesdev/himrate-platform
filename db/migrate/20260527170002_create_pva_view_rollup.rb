# frozen_string_literal: true

# TASK-113 BE-2 (FR-001..005; scalable storage, PO 2026-05-27): daily rollup для PVA Overview.
# PG-аналог будущего ClickHouse AggregatingMergeTree MV. pva_view_events (raw) + pva_view_rollups =
# CH-cutover-targets платформенного ClickHouse EPIC (TASK-251.14) — мигрируют ВМЕСТЕ со всей аналитикой
# (trends_daily_aggregates / chat / :signals), rollup→AggregatingMergeTree маппинг 1:1. См. CONTEXT.
#
# Overview (M1-M5) читает rollup (fast, per-user scoped), НЕ сырьё. Зеркало trends_daily_aggregates
# (native PARTITION BY RANGE(date) + composite PK + UNIQUE с partition key).
# Granularity (user_id, twitch_channel_id, game_id, date): M2 group-by-channel · M3 group-by-game ·
# M1 SUM · M5 first_seen_at · M4 heatmap (day-of-week из date × hour-of-day из hour_histogram) ·
# M1 device-сегмент из device_seconds. twitch_channel_id = стабильный ключ; channel_id(uuid)/twitch_login
# = enrichment (если канал трекается). game_id NOT NULL DEFAULT '' (sentinel «unknown») — избегает
# NULL-distinct дублей в UNIQUE при upsert on_conflict.
# Retention: НЕТ (lifetime — M1 window=all / Spotify-Wrapped). Raw pva_view_events = 2y (160009);
# rollup = durable lifetime store.
class CreatePvaViewRollup < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE pva_view_rollups (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        twitch_channel_id varchar(30) NOT NULL,
        channel_id uuid,
        twitch_login varchar(50),
        game_id varchar(30) NOT NULL DEFAULT '',
        date date NOT NULL,
        total_seconds bigint NOT NULL DEFAULT 0,
        session_count integer NOT NULL DEFAULT 0,
        first_seen_at timestamp(6) without time zone NOT NULL,
        last_seen_at timestamp(6) without time zone NOT NULL,
        hour_histogram jsonb NOT NULL DEFAULT '{}',
        device_seconds jsonb NOT NULL DEFAULT '{}',
        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        PRIMARY KEY (id, date),
        UNIQUE (user_id, twitch_channel_id, game_id, date)
      ) PARTITION BY RANGE (date);
    SQL

    execute(<<~SQL)
      CREATE TABLE pva_view_rollups_default PARTITION OF pva_view_rollups DEFAULT;
    SQL

    add_index :pva_view_rollups, %i[user_id date], name: "idx_pva_rollup_user_date"
    add_index :pva_view_rollups, %i[user_id twitch_channel_id date], name: "idx_pva_rollup_user_channel"
  end

  def down
    drop_table :pva_view_rollups
  end
end
