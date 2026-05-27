-- TASK-251.14 (PR 1a-2): incremental analytics rollups for the ContextBuilder chat queries.
--
-- AggregatingMergeTree materialized views — each MV is a trigger on INSERT into chat_messages: every
-- inserted block is aggregated into partial states in the target table, background merges combine
-- states across blocks, and reads combine them with the *Merge combinators. Signals then read tiny
-- per-minute rollups instead of re-scanning the 11 GB raw history (the disk-I/O root cause).
--
-- Two MVs cover three of ContextBuilder's four chat queries:
--   • mv_stream_minute       → fetch_chat_rate (privmsg/min, 10min) + fetch_unique_chatters (60min)
--   • mv_stream_user_minute  → fetch_chat_username_counts (per-user counts → Shannon entropy, 5min)
--
-- The fourth query, fetch_cross_channel (distinct channels per user, ROLLING 24h GLOBAL), is read
-- directly from the raw columnar chat_messages — NOT an MV (decided 2026-05-27, PO-approved, revising
-- the SRS's day-bucketed mv_user_channels_daily): the DSV measured that raw columnar scan at ~30 ms,
-- and the raw read keeps the EXACT rolling-24h semantics — so the 1d dual-read can flip at true
-- 0-divergence vs Postgres (DEC-7), which a day/hour-bucketed MV could not.
--
-- WHERE mirrors ContextBuilder exactly: msg_type='privmsg' AND a non-null stream_id (its queries are
-- always scoped to a specific stream). assumeNotNull() is safe under that WHERE and lets the target
-- key stay non-nullable UUID. Idempotent (IF NOT EXISTS) — re-applied on every clickhouse:setup.

CREATE TABLE IF NOT EXISTS mv_stream_minute_target
(
    stream_id        UUID,
    minute           DateTime,
    msg_count        AggregateFunction(count),
    unique_chatters  AggregateFunction(uniq, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (stream_id, minute)
PARTITION BY toYYYYMMDD(minute);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_stream_minute TO mv_stream_minute_target AS
SELECT
    assumeNotNull(stream_id)   AS stream_id,
    toStartOfMinute(timestamp) AS minute,
    countState()               AS msg_count,
    uniqState(username)        AS unique_chatters
FROM chat_messages
WHERE msg_type = 'privmsg' AND stream_id IS NOT NULL
GROUP BY stream_id, minute;

CREATE TABLE IF NOT EXISTS mv_stream_user_minute_target
(
    stream_id  UUID,
    minute     DateTime,
    username   String,
    msg_count  AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (stream_id, minute, username)
PARTITION BY toYYYYMMDD(minute);

CREATE MATERIALIZED VIEW IF NOT EXISTS mv_stream_user_minute TO mv_stream_user_minute_target AS
SELECT
    assumeNotNull(stream_id)   AS stream_id,
    toStartOfMinute(timestamp) AS minute,
    username,
    countState()               AS msg_count
FROM chat_messages
WHERE msg_type = 'privmsg' AND stream_id IS NOT NULL
GROUP BY stream_id, minute, username;
