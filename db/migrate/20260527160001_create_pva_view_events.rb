# frozen_string_literal: true

# TASK-113 BE-1 (FR-001..005): Personal Viewer Analytics viewing-event store.
# Источник = SyncEvent stream_view (FR-021/TASK-110) → ViewAggregationWorker раскладывает
# сюда per-сессию. Питает M1 Hero / M2 Top Streamers / M3 Categories / M4 Heatmap / M5 Discovery.
#
# NATIVE PARTITIONED BY RANGE(started_at) — эталон trends_daily_aggregates (TASK-039):
# 1. PARTITION BY RANGE объявляется в CREATE TABLE (нет ALTER).
# 2. Partition key (started_at) обязан быть в КАЖДОМ UNIQUE/PK → PRIMARY KEY (id, started_at).
# 3. Default partition ловит все даты (safety net dev/test; prod pg_partman создаёт monthly).
# Append-only события (несколько сессий на канал) — без natural-key uniqueness.
class CreatePvaViewEvents < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE pva_view_events (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        channel_id uuid REFERENCES channels(id) ON DELETE SET NULL,
        twitch_login varchar(50),
        game_id varchar(30),
        started_at timestamp(6) without time zone NOT NULL,
        seconds integer NOT NULL DEFAULT 0,
        device varchar(20),
        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        PRIMARY KEY (id, started_at)
      ) PARTITION BY RANGE (started_at);
    SQL

    execute(<<~SQL)
      CREATE TABLE pva_view_events_default
        PARTITION OF pva_view_events DEFAULT;
    SQL

    add_index :pva_view_events, %i[user_id started_at], name: "idx_pva_view_user_time"
    add_index :pva_view_events, %i[user_id channel_id], name: "idx_pva_view_user_channel"
    add_index :pva_view_events, %i[user_id game_id],
      where: "game_id IS NOT NULL", name: "idx_pva_view_user_game"
  end

  def down
    drop_table :pva_view_events
  end
end
