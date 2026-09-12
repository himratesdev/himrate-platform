-- EPIC FARM T-F1: chat captured from the farm's category-join IRC pool (bin/irc_capture).
--
-- Deliberately a SEPARATE table from `chat_messages`:
--   * `chat_messages` is the bot-detection archive — CrossChannelIntelligenceWorker scans its whole
--     24h slice every 5 min and the overlap / temporal-flag products are RU-market signals. Mixing
--     ~20M/day of multi-language category chat in would 6x that scan and pollute the graph.
--   * The farm needs raw chat only for moment detection around peaks (T-F3) — 30 days is plenty,
--     so this table has a TTL instead of the forever-tiered retention of `chat_messages` (DEC-4).
--   * No stream_id (the capture set has no Stream rows) and no materialized views (T-F3 defines
--     its own reads); `game_id` is stamped at drain time from the capture set so the farm can slice
--     by category without a join.
--
-- Column set otherwise mirrors `chat_messages` 1:1 (same Clickhouse::ChatRow mapper) so any
-- `chat_messages` reader can be pointed at this table with a UNION ALL when a farm channel is also
-- a monitored one. Idempotent (IF NOT EXISTS) — applied by `rake clickhouse:setup` on every boot.

CREATE TABLE IF NOT EXISTS capture_chat_messages
(
    game_id            LowCardinality(String),
    channel_login      LowCardinality(String),
    username           String,
    msg_type           LowCardinality(String),
    subscriber_status  LowCardinality(String),
    user_type          LowCardinality(String),
    is_first_msg       UInt8,
    returning_chatter  UInt8,
    vip                UInt8,
    bits_used          UInt32,
    display_name       String,
    badge_info         String,
    color              String,
    twitch_msg_id      String,

    message_text       String CODEC(ZSTD(3)),
    emotes             String CODEC(ZSTD(3)),
    raw_tags           String CODEC(ZSTD(3)),

    timestamp          DateTime64(3),
    -- 'twitch' | 'local' | 'drain' — see 008_add_ts_source_to_chat.sql. Matters more here than on
    -- the monitored table: this is the wide corpus (178k channels) any cross-channel timing signal
    -- will be built on, and a five-second co-occurrence window cannot afford two seconds of our
    -- own clock noise.
    ts_source          LowCardinality(String) DEFAULT 'local',
    inserted_at        DateTime DEFAULT now(),

    -- game_id is not in the primary key (per-channel windows are the hot read; T-F3). A category-wide
    -- slice would otherwise full-scan the partition, so a `set` skipping index carries it: within a
    -- granule game_id is (near-)constant because rows are ordered by channel and a channel sits in
    -- one category at a time — a set of ≤8 distinct values per 4 granules skips ~all foreign
    -- categories (CR iter-1 N6). Cheap: LowCardinality column, a few bytes per index granule.
    INDEX idx_game_id game_id TYPE set(8) GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (channel_login, timestamp) -- per-channel windowed scans (peak detection around a clip)
PARTITION BY toYYYYMMDD(timestamp)  -- daily partitions: TTL drops whole parts, cheap pruning
TTL toDateTime(timestamp) + INTERVAL 30 DAY; -- design decision §8: monthly top-20 needs 30d, 14d too short
