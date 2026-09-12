-- 2026-09-12: record WHICH CLOCK stamped every chat row.
--
-- WHY:
--   Until today `Twitch::IrcParser#to_record` stamped `Time.current` at the moment it parsed the
--   IRC line, and threw away the `tmi-sent-ts` tag — Twitch's own NTP-synced send time, in
--   milliseconds — into the cold `raw_tags` blob where nothing ever read it. Measured on a day of
--   live traffic (300k privmsg rows), our clock sat 305 ms behind Twitch's at the median and
--   wandered from −815 ms to +1910 ms at the tails.
--
--   That wander was being read as data by everything temporal we own: the minute buckets of
--   `mv_stream_minute` / `mv_stream_user_minute` are `toStartOfMinute(timestamp)`, so every bucket
--   boundary was fuzzed by up to two seconds; the cross-channel co-occurrence window is FIVE
--   seconds wide, so ~40% of its width was clock noise; and any lead/lag we ever try to measure
--   between channels was measuring our own scheduler.
--
--   Worse, both drain workers silently substituted their OWN clock — up to two minutes later than
--   the event — whenever a payload arrived without a parseable timestamp. A row stamped two
--   minutes late is indistinguishable from a row stamped on time, and it was indistinguishable on
--   purpose: there was nowhere to record the difference.
--
-- WHAT:
--   `ts_source` travels with every row and says whose clock produced `timestamp`:
--     'twitch' — `tmi-sent-ts`, Twitch's server clock, millisecond precision. The good case.
--     'local'  — our process clock at IRC parse time. Used where Twitch sends no tag at all
--                (ROOMSTATE and friends) and for every row written before this migration.
--     'drain'  — our clock at drain time, up to ~2 min late. Only when the payload reached the
--                drain worker with no usable time. Exclude these from anything temporal.
--
-- IDEMPOTENCY: `IF NOT EXISTS` makes the ALTER a no-op on re-run, and `bin/docker-entrypoint`
-- re-runs `clickhouse:setup` on every container boot.
--
-- NO MUTATION ON PURPOSE: a DEFAULT'd column is synthesised at read time for parts written before
-- the ALTER, so the ~58M existing rows read back as 'local' at zero rewrite cost — and 'local' is
-- exactly what they were. Issuing MATERIALIZE here would rewrite every historical part to store a
-- constant we can derive for free.
--
-- HISTORY IS NOT LOST: `tmi-sent-ts` is present inside `raw_tags` on every historical privmsg, so
-- the true send time of past rows stays recoverable with
-- `JSONExtractInt(raw_tags, 'tmi-sent-ts')` without rewriting a single partition.

ALTER TABLE chat_messages
    ADD COLUMN IF NOT EXISTS ts_source LowCardinality(String) DEFAULT 'local'
    AFTER timestamp;

ALTER TABLE capture_chat_messages
    ADD COLUMN IF NOT EXISTS ts_source LowCardinality(String) DEFAULT 'local'
    AFTER timestamp;
