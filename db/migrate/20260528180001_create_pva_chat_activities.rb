# frozen_string_literal: true

# TASK-113 BE-3 (FR-006, M6 Communities): daily rollup активности зрителя в чате per канал.
# Источник = client-capture (extension наблюдает СВОИ сообщения — DSV «M6 chat-capture pattern»,
# variant A PO-approved). Snapshot-upsert ingest (ChatActivityIngestWorker): идемпотентно by replace
# per (user, channel, date). M6 читает: activity_level (high/mid/low/min из message_count) + top_emotes
# (из emote_counts). PG-аналог CH AggregatingMergeTree — CH-cutover-target (как pva_view_rollups).
# Зеркало pva_view_rollups (native PARTITION BY RANGE(date) + composite PK + UNIQUE с partition key),
# key = (user_id, twitch_channel_id, date) (без game-измерения — M6 per-канал). twitch_channel_id =
# стабильный ключ; channel_id(uuid)/twitch_login = enrichment если канал tracked. Lifetime (no retention).
class CreatePvaChatActivities < ActiveRecord::Migration[8.0]
  def up
    execute(<<~SQL)
      CREATE TABLE pva_chat_activities (
        id uuid NOT NULL DEFAULT gen_random_uuid(),
        user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        twitch_channel_id varchar(30) NOT NULL,
        channel_id uuid,
        twitch_login varchar(50),
        date date NOT NULL,
        message_count integer NOT NULL DEFAULT 0,
        emote_counts jsonb NOT NULL DEFAULT '{}',
        first_seen_at timestamp(6) without time zone NOT NULL,
        last_seen_at timestamp(6) without time zone NOT NULL,
        created_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        updated_at timestamp(6) without time zone NOT NULL DEFAULT now(),
        PRIMARY KEY (id, date),
        UNIQUE (user_id, twitch_channel_id, date)
      ) PARTITION BY RANGE (date);
    SQL

    execute(<<~SQL)
      CREATE TABLE pva_chat_activities_default PARTITION OF pva_chat_activities DEFAULT;
    SQL

    add_index :pva_chat_activities, %i[user_id date], name: "idx_pva_chat_user_date"
    add_index :pva_chat_activities, %i[user_id twitch_channel_id date], name: "idx_pva_chat_user_channel"
  end

  def down
    drop_table :pva_chat_activities
  end
end
