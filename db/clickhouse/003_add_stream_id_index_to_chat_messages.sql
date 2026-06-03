-- Phase 6 M (2026-06-03): backfill the `idx_stream_id` bloom_filter skipping index onto existing
-- `chat_messages` instances (staging / production). New environments pick up the index from the
-- updated `001_chat_messages.sql` `CREATE TABLE … INDEX idx_stream_id …` clause; this migration
-- exists for instances that were created before the index landed.
--
-- WHY:
--   `chat_messages` ORDER BY (channel_login, timestamp) is purpose-built for per-channel windowed
--   reads. The Clickhouse::ChatQueries.privmsg_counts_for_streams call (used by
--   Ml::Features::StabilitySignals#chat_rates_per_stream batch path) filters by `stream_id` only —
--   no `channel_login` or `timestamp` predicate — so without a skipping index the query
--   full-scans every daily partition (~50M+ rows / 7 days at staging volume). Measured 6×
--   variance on the same query (196ms → 1293ms across trials), with empty-stream queries hitting
--   3794ms. Bloom filter ~1-2% storage overhead skips ~99% of granules per partition for typical
--   per-stream lookups → expected 200-3000ms → 20-200ms (≥10× win) and variance < 2× target.
--
-- IDEMPOTENT: `IF NOT EXISTS` on ADD INDEX = no-op if the column already has it. `MATERIALIZE` is
-- safe to re-run (background mutation; the mutation log dedupes by index name + table version).
--
-- MATERIALIZE is REQUIRED — `ADD INDEX` only registers the index in the schema; existing parts
-- stay unindexed until either a `MATERIALIZE INDEX` is issued (rewrites their secondary index
-- files in the background) or a part is rewritten organically via OPTIMIZE / MERGE. Without it,
-- only data inserted after this DDL benefits from the skip.
--
-- BACKGROUND COST: `MATERIALIZE INDEX` runs as a background mutation; staging has ~40M
-- chat_messages rows in 7 daily partitions. Empirically ClickHouse 24.x re-indexes a bloom filter
-- at ~5-15 MiB/s per part; the staging table is ~106 MiB across the dimension columns we care
-- about (DSV-measured), so the mutation completes in seconds-to-minutes. Production may take
-- longer but is non-blocking — reads continue against the un-materialized parts (slow path) and
-- transparently switch to the skip path as parts complete. Doc:
-- `_tasks/Phase-6-M-privmsg-variance/CONTEXT.md`.

ALTER TABLE chat_messages
    ADD INDEX IF NOT EXISTS idx_stream_id stream_id TYPE bloom_filter GRANULARITY 4;

ALTER TABLE chat_messages MATERIALIZE INDEX idx_stream_id;
