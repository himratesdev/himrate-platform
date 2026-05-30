# frozen_string_literal: true

module Clickhouse
  # TASK-251.14c: backfill historical Postgres chat_messages into ClickHouse up to a T0 watermark
  # (the timestamp at which the live dual-write was enabled per env). Post-T0 rows are already
  # covered by the live mirror (ChatMessageWorker#mirror_to_clickhouse, PR 1b); the backfill closes
  # the historical gap so signals can read EVERYTHING from CH after the read-migration (PR 1d).
  #
  # ⚠️ T0 SAFETY MARGIN (queue-drain dedup window): set T0 = `Flipper.enable(:chat_writes_clickhouse)`
  # time + safety margin PAST FULL DRAIN of the Redis chat queue (`irc:chat_messages`). ChatMessageWorker
  # drains every minute on cron; messages with `tmi-sent-ts < enable_time` can still be sitting in
  # the queue when the flag flips ON, and the next drain mirrors them to CH with their original
  # (pre-enable) timestamp. If T0 is set to the enable_time exactly, this small tail is BOTH live-
  # mirrored AND picked up by the backfill (`timestamp < T0` matches both) → duplicates in CH (the
  # raw table is MergeTree, NOT ReplacingMergeTree — no engine-level dedup). Recommend T0 ≥
  # enable_time + 2× drain cadence + IRC ingest lag (≈ 2–3 minutes). PR 1d's parity gate spot-checks
  # for duplicate `twitch_msg_id` before flipping read.
  #
  # Operator-invoked via `rake clickhouse:backfill_chat[t0_iso]`. The rake task calls #call to
  # seed T0 in Redis and exits; the actual backfill loop runs in Clickhouse::ChatBackfillCycleWorker
  # (Sidekiq cron, every minute — survives container swaps natively). Idempotent + resumable:
  # cursor stored in Redis (AOF-durable). Kill-switch: Flipper flag :chat_backfill_running — flip
  # OFF and the next #tick returns :paused (cursor preserved). Failure path: CH error → set
  # Redis status=failed + last_error, return :failed WITHOUT advancing the cursor (operator
  # inspects via `rake clickhouse:backfill_chat_status`; the next cron tick auto-retries the same
  # batch — for transient errors this is the desired behavior).
  #
  # Cursor is the Postgres UUID PK ordered ascending (id > cursor). UUIDv4 PK has NO timestamp
  # correlation (`gen_random_uuid()` is random) — so pre-T0 and post-T0 rows are scattered evenly
  # through the id range. The PK btree gives a fast forward scan regardless, and PG applies the
  # `timestamp < T0` filter as it streams; the post-T0 minority is discarded in the same scan.
  class ChatBackfill
    REDIS_PREFIX = "clickhouse:backfill:chat"
    DEFAULT_BATCH_SIZE = 5_000
    DEFAULT_SLEEP_SECONDS = 0.5
    # "Before all UUIDs" seed for the first run — every real UUID compares strictly greater.
    NULL_UUID = "00000000-0000-0000-0000-000000000000"
    LOG_EVERY_N_BATCHES = 10

    Result = Struct.new(:status, :rows_processed, :batches, :elapsed_seconds, keyword_init: true)

    def self.call(**opts)
      new(**opts).call
    end

    # CR iter5 N2: `sleep_seconds:` removed — #call is now seed-only (no loop, no sleep);
    # #tick is single-shot (no sleep). The cron worker uses its own INTER_BATCH_SLEEP_SECONDS
    # between #tick calls. The constant DEFAULT_SLEEP_SECONDS is kept for documentation but no
    # longer referenced in this class.
    def initialize(t0:, batch_size: DEFAULT_BATCH_SIZE,
                   redis: nil, client: nil, logger: Rails.logger)
      @t0 = t0.is_a?(Time) ? t0 : parse_t0!(t0)
      @batch_size = batch_size
      @redis = redis || Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      @client = client || Clickhouse.client
      @logger = logger
    end

    def parse_t0!(value)
      Time.parse(value)
    rescue ArgumentError, TypeError
      raise ArgumentError, "T0 must be parseable as a Time (ISO8601 recommended), got: #{value.inspect}"
    end
    private :parse_t0!

    # Seed T0 in Redis and exit. The actual backfill loop runs in Clickhouse::ChatBackfillCycleWorker
    # (Sidekiq cron, every minute, survives container swaps natively). The rake task wrapper
    # `rake clickhouse:backfill_chat[T0]` calls this method to set the watermark; the cron worker
    # picks T0 up from Redis on its next tick.
    #
    # CR iter4 M1: the previous blocking-loop implementation here held a lock with TTL=80s while
    # the loop ran for hours — the cron worker would steal the lock after TTL expiry → concurrent
    # #tick → duplicate inserts in no-engine-dedup CH MergeTree (the exact race iter3 Should-1
    # was supposed to fix). The clean fix is to remove the rake's blocking loop entirely: it was
    # the operator-driven pattern this entire TASK-251.58 replaces. Operators monitor progress
    # via `rake clickhouse:backfill_chat_status` (read-only Redis dump) or tail Sidekiq logs.
    #
    # Returns a Result with status="seeded" — distinct from "done"/"paused"/"failed" so callers
    # (rake task wrapper) can tell apart "T0 was set, worker will take it" from terminal states.
    def call
      @redis.set("#{REDIS_PREFIX}:t0", @t0.iso8601)
      cursor = @redis.get("#{REDIS_PREFIX}:cursor_id") || NULL_UUID
      rows_so_far = @redis.get("#{REDIS_PREFIX}:rows_processed").to_i
      @logger.info("ChatBackfill: T0 seeded t0=#{@t0.iso8601} cursor=#{cursor} rows_so_far=#{rows_so_far}. Cron-driven Clickhouse::ChatBackfillCycleWorker will resume on next tick (≤60s). Monitor via `rake clickhouse:backfill_chat_status` or Sidekiq logs.")
      Result.new(status: "seeded", rows_processed: rows_so_far, batches: 0, elapsed_seconds: 0)
    end

    # TASK-251.58: single-batch operation. Called by ChatBackfillCycleWorker (Sidekiq cron with
    # timeboxed deadline; survives container swaps natively, unlike the prior detached-rake
    # pattern which died on every Kamal deploy — observed 4× swap kills during TASK-251.14
    # backfill window 2026-05-29). The worker is the sole #tick caller after CR iter4 dropped
    # the rake blocking loop. Single-writer assumption: this method is idempotent at the cursor
    # level under a single concurrent writer (Redis cursor advances monotonically). It is NOT
    # inherently concurrency-safe — two parallel ticks would both read the same Redis cursor,
    # fetch the same PG batch, and double-insert into the no-engine-dedup CH MergeTree.
    # ChatBackfillCycleWorker enforces single-writer via the Clickhouse::BackfillCycleLock SETNX
    # lock around the #tick loop (overlap guard against multi-instance worker OR overrun-tick).
    #
    # Return value (Hash):
    #   { status: :ok,     cursor:, batch_size:, rows_processed: }  - batch inserted, more remaining
    #   { status: :done,   cursor:, rows_processed: }               - no rows match `id > cursor AND timestamp < T0`
    #   { status: :paused, cursor:, rows_processed: }               - :chat_backfill_running OFF (kill-switch)
    #   { status: :failed, cursor:, batch_size:, rows_processed:, last_error: }  - CH insert error; Redis status="failed"
    def tick
      cursor = @redis.get("#{REDIS_PREFIX}:cursor_id") || NULL_UUID
      rows_processed = @redis.get("#{REDIS_PREFIX}:rows_processed").to_i

      unless Flipper.enabled?(:chat_backfill_running)
        return { status: :paused, cursor: cursor, rows_processed: rows_processed }
      end

      batch = fetch_batch(cursor)
      if batch.empty?
        @redis.set("#{REDIS_PREFIX}:status", "done")
        return { status: :done, cursor: cursor, rows_processed: rows_processed }
      end

      rows = batch.map { |record| ChatRow.from_pg(record.attributes) }

      begin
        @client.insert("chat_messages", rows)
      rescue Clickhouse::Error => e
        @redis.set("#{REDIS_PREFIX}:status", "failed")
        @redis.set("#{REDIS_PREFIX}:last_error", "#{e.class}: #{e.message.truncate(500)}")
        return { status: :failed, cursor: cursor, batch_size: batch.size,
                 rows_processed: rows_processed, last_error: "#{e.class}: #{e.message.truncate(200)}" }
      end

      new_cursor = batch.last.id
      new_rows_processed = rows_processed + batch.size
      @redis.set("#{REDIS_PREFIX}:cursor_id", new_cursor)
      @redis.set("#{REDIS_PREFIX}:rows_processed", new_rows_processed.to_s)
      @redis.set("#{REDIS_PREFIX}:status", "running")
      # CR iter5 N1: clear last_error on a successful subsequent tick so `rake backfill_chat_status`
      # doesn't show a stale error message hours after the transient CH failure recovered. The
      # backfill is back to healthy ticking — operators reading the status should see that, not
      # the message from the now-resolved failure.
      @redis.del("#{REDIS_PREFIX}:last_error")

      { status: :ok, cursor: new_cursor, batch_size: batch.size, rows_processed: new_rows_processed }
    end

    private

    def fetch_batch(cursor)
      ChatMessage
        .where("id > ? AND timestamp < ?", cursor, @t0)
        .order(:id)
        .limit(@batch_size)
        .to_a
    end
  end
end
