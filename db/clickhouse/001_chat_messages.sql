-- TASK-251.14 (PR 1a): raw chat archive + source table for the incremental analytics MVs (PR 1a-2).
--
-- Mirrors the Postgres chat_messages ingest contract (ChatMessageWorker#parse_message) 1:1 so the
-- dual-write (PR 1b) maps each record with no transform. Columnar layout is the whole point: the
-- analytics scans (ContextBuilder's 5 chat queries) read only the skinny dimension columns
-- (channel_login / username / msg_type / timestamp / ...), never the heavy text/JSON archive
-- columns. The DSV measured that working set at ~106 MiB for ALL chat (fits RAM) vs the 11 GB
-- row-store that does not — that is the disk-I/O win.
--
-- Idempotent (IF NOT EXISTS) so `rake clickhouse:setup` is safe to re-run on every deploy/CI run.
-- The database itself is created by the accessory (CLICKHOUSE_DB env, config/deploy.yml) / the CI
-- service container; this file manages only tables & views inside it (selected via the
-- X-ClickHouse-Database header, so the SQL stays database-agnostic across staging/production/test).

CREATE TABLE IF NOT EXISTS chat_messages
(
    -- Dimensions (hot path — analytics reads these). LowCardinality = strong compression + fast
    -- equality filters on the handful of distinct logins / message & sub types.
    stream_id          Nullable(UUID),
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

    -- Archive (cold — never read on the hot path). ZSTD folds in the wave-1 compression optimisation
    -- at the cheapest moment (empty table), avoiding a later full-table re-merge. DSV: raw_tags
    -- dominates the archive (9.69 MiB / 3.5x at LZ4) — ZSTD shrinks it further.
    message_text       String CODEC(ZSTD(3)),
    emotes             String CODEC(ZSTD(3)),
    raw_tags           String CODEC(ZSTD(3)),

    timestamp          DateTime64(3),
    -- Ingestion bookkeeping (observability / dual-write lag). DateTime DEFAULT now() costs ~nothing.
    inserted_at        DateTime DEFAULT now(),

    -- Phase 6 M (2026-06-03): bloom_filter skipping index on stream_id. The primary ORDER BY is
    -- (channel_login, timestamp) — purpose-built for ContextBuilder's per-channel windowed scans.
    -- But `stream_id` lookups (Clickhouse::ChatQueries.privmsg_counts_for_streams, called by the
    -- Ml::Features::StabilitySignals#chat_rates_per_stream batch path) filter ONLY by stream_id
    -- with no channel_login / timestamp predicate, so without this index they full-scan all daily
    -- partitions in the retention window (~50M+ rows / 7 days at staging volume) on every call —
    -- measured 6× variance same query (196ms → 1293ms) before the index. Bloom filter granules
    -- skip ~99% of granules per partition for a typical per-stream lookup. GRANULARITY 4 = one
    -- bloom filter entry per 4 index granules (8192 rows × 4 = 32k rows per bloom entry) — balances
    -- storage cost (~1-2% of table size) vs skip resolution. Doc:
    -- _tasks/Phase-6-M-privmsg-variance/CONTEXT.md.
    INDEX idx_stream_id stream_id TYPE bloom_filter GRANULARITY 4
)
ENGINE = MergeTree
ORDER BY (channel_login, timestamp) -- per-channel / per-stream windowed scans + cross-channel
PARTITION BY toYYYYMMDD(timestamp); -- daily partitions: cheap retention + partition pruning
-- Retention = forever (ADR DEC-4: forever-tiered). No DROP TTL. Hot/cold recompress-tiering needs a
-- storage policy with a cold volume the single-disk VPS does not have yet — it lands with the
-- measured hardware migration; until then ZSTD on the archive columns carries the footprint.
