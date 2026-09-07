-- Audience-overlap presence layer: one row per (day, channel, chatter), fed by BOTH chat sources,
-- with per-source message counts kept SEPARATE so provenance is never lost.
--
-- Why: the overlap products (pautinka graph / brand overlap) read only the Postgres
-- `cross_channel_presences` ledger, which covers just the monitored set and restarted from zero
-- with the 2026-08 server migration — pairs of real channels showed "0 shared" because the data
-- wasn't there, not because the audiences don't overlap. Meanwhile ClickHouse ALREADY holds both
-- the monitored chat archive (`chat_messages`) and the farm's category-join capture
-- (`capture_chat_messages`, ~20k active channels / ~870k distinct user-channel pairs per day).
-- This table distills those two into the only shape overlap needs, so no new capture is required
-- and Postgres does not grow at all.
--
-- MIXED-SOURCE DISCIPLINE (the thing that could otherwise make numbers disagree across screens):
--   * Dedup: SummingMergeTree over (date, channel_login, username) — a channel that is BOTH
--     monitored and in the farm pool contributes ONE presence row; a chatter is never counted twice.
--   * Provenance kept: `messages_monitored` / `messages_farm` sum independently, so any read can
--     ask "monitored-only" (identical population to the Trust Index engine) or "all sources"
--     (denser, for overlap). Nothing is silently blended.
--   * Verdicts DO NOT read this table. TI / band / ERV keep running on `chat_messages` alone
--     (design decision in 004: farm chat must not enter bot-detection). This layer answers a
--     different question — "who else does this audience watch" — and never feeds an accusation.
--   * Coverage asymmetry is measurable, not hidden: the farm pool rotates, so a channel may be
--     observed on fewer days than a monitored one. Readers derive `days_observed` per channel from
--     this same table and can flag/normalize a thin-coverage pair instead of quietly under-reporting.
--
-- Retention: 90 days. NB the farm source itself keeps only 30 days (capture TTL), so rows older
-- than that are monitored-only by construction — readers that go past 30 days must say so.
--
-- Idempotent (IF NOT EXISTS) — applied by `rake clickhouse:setup` on every boot/deploy.

CREATE TABLE IF NOT EXISTS chat_presence_daily
(
    date                Date,
    channel_login       LowCardinality(String),
    username            String,
    messages            UInt32,
    messages_monitored  UInt32,
    messages_farm       UInt32
)
ENGINE = SummingMergeTree((messages, messages_monitored, messages_farm))
ORDER BY (date, channel_login, username) -- dedup key: one presence per chatter per channel per day
PARTITION BY toYYYYMM(date)
TTL date + INTERVAL 90 DAY;

-- The MVs aggregate WITHIN each inserted block; SummingMergeTree finishes the job across blocks.
-- Backfill of pre-existing rows is a one-off `INSERT INTO chat_presence_daily SELECT ...` (an MV
-- only sees new inserts) — see Chat::PresenceQuery for the read side.

CREATE MATERIALIZED VIEW IF NOT EXISTS chat_presence_daily_mv_monitored
TO chat_presence_daily AS
SELECT
    toDate(timestamp) AS date,
    channel_login,
    username,
    count() AS messages,
    count() AS messages_monitored,
    toUInt32(0) AS messages_farm
FROM chat_messages
WHERE username != ''
GROUP BY date, channel_login, username;

CREATE MATERIALIZED VIEW IF NOT EXISTS chat_presence_daily_mv_farm
TO chat_presence_daily AS
SELECT
    toDate(timestamp) AS date,
    channel_login,
    username,
    count() AS messages,
    toUInt32(0) AS messages_monitored,
    count() AS messages_farm
FROM capture_chat_messages
WHERE username != ''
GROUP BY date, channel_login, username;
