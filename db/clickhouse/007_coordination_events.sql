-- Coordination layer: WHICH channels a co-firing account writes in.
--
-- Why this table exists at all. T1-057 already detects the account side of coordinated chat: the
-- `temporal_co_occurrence` query finds accounts that posted in >=3 DISTINCT channels inside a <=5s
-- window and counts the recurrences. But it collapses the channels through `uniqExact()` and keeps
-- only two scalars per account (event_count, max_concurrent) — the channel IDENTITIES are thrown
-- away. The audience-overlap layer has the mirror-image gap: `Chat::PresenceQuery` deliberately
-- EXCLUDES accounts present in >30 channels (serial-lurker cap), i.e. exactly the population we
-- want here. So nothing in the system could answer "which channels share the same pool of
-- co-firing accounts" — the single most damning thing our data actually knows.
--
-- This table keeps the identities. One row = (hour, account) with the set of channels that account
-- co-fired in during that hour. Groups are assembled at read time (Coordination::GroupBuilder):
-- accounts → channel pairs → connected components.
--
-- INCREMENTAL BY HOUR, not a 24h snapshot-recompute. Two reasons:
--   * Cost. One hour of chat is ~160k rows; the old 24h scan over the 2-phase grid is ~7.6M and
--     blew a 3.7 GiB query budget on the 16 GB box when the channel arrays were added.
--   * Correctness. Channels do not stream daily. dear_hellgirl's ring was invisible in a 24h window
--     purely because she was offline that day — verified live 2026-09-09: 1051 of the co-firing
--     accounts write in her chat over 7 days, and her top overlap neighbours ARE the ring. Group
--     assembly therefore reads a 7-day window; the hourly rows make that affordable.
--
-- MONITORED ONLY. The source is `chat_messages` — the farm's `capture_chat_messages` is never read
-- here. Coordination feeds an accusation on the public channel card, and the farm firewall
-- (see 004/005) says farm chat must not enter one. Readers surface this as `basis_source`.
--
-- ReplacingMergeTree on (hour, username): re-running a collector for an hour REPLACES that hour
-- instead of double-counting, so a retry or a backfill is idempotent.
--
-- Retention 30 days: group assembly looks back 7, and the extra headroom covers a stalled worker
-- plus "first seen" continuity across a redeploy.
--
-- Idempotent (IF NOT EXISTS) — applied by `rake clickhouse:setup` on every boot/deploy.

CREATE TABLE IF NOT EXISTS coordination_events
(
    hour            DateTime,       -- hour slice this row was computed for (UTC, start of hour)
    username        String,
    events          UInt32,         -- >=3-channel bursts by this account inside the hour
    max_concurrent  UInt16,         -- widest burst: distinct channels in one <=5s window
    channels        Array(String),  -- the identities T1-057 discards; union over both phase grids
    last_at         DateTime        -- last co-firing message in the hour (also the Replacing version)
)
ENGINE = ReplacingMergeTree(last_at)
ORDER BY (hour, username)
PARTITION BY toYYYYMMDD(hour)
TTL hour + INTERVAL 30 DAY;
