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
  # Operator-invoked via `rake clickhouse:backfill_chat[t0_iso,batch_size,sleep_seconds]`. Idempotent
  # + resumable: cursor stored in Redis (AOF-durable). Re-running picks up where it left off.
  # Kill-switch: Flipper flag :chat_backfill_running. Flip OFF → loop exits cleanly after the current
  # batch (cursor preserved). Failure path: CH error → log + status=failed + exit WITHOUT advancing
  # the cursor (operator inspects, then re-runs to resume from the same batch).
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

    def initialize(t0:, batch_size: DEFAULT_BATCH_SIZE, sleep_seconds: DEFAULT_SLEEP_SECONDS,
                   redis: nil, client: nil, logger: Rails.logger)
      @t0 = t0.is_a?(Time) ? t0 : parse_t0!(t0)
      @batch_size = batch_size
      @sleep_seconds = sleep_seconds
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

    # Operator-driven blocking loop (original rake-task entry point). Kept for backward-compat:
    # ad-hoc one-shot backfill via `rake clickhouse:backfill_chat` still works the same way.
    # The TASK-251.58 Sidekiq cron path (ChatBackfillCycleWorker) calls #tick directly with a
    # timeboxed deadline so it survives container swaps natively.
    #
    # CR iter3 Should-1: both entry points MUST share `:cycle_lock` (Clickhouse::BackfillCycleLock)
    # — otherwise the rake operator path and the cron worker would both call #tick concurrently
    # and double-insert into the no-engine-dedup CH MergeTree. Acquires lock at top, releases in
    # ensure. If lock is already held (the cron worker is running or another operator-rake is in
    # flight), abort with a clear message rather than block.
    def call
      @redis.set("#{REDIS_PREFIX}:t0", @t0.iso8601)
      lock_token = SecureRandom.hex(16)
      unless BackfillCycleLock.acquire(@redis, lock_token)
        @logger.error("ChatBackfill: cycle lock already held — refusing to start a concurrent rake-driven loop. Wait for the cron-driven ChatBackfillCycleWorker (or other operator-rake) to finish, then re-run.")
        return Result.new(status: "lock_busy", rows_processed: 0, batches: 0, elapsed_seconds: 0)
      end

      begin
        @redis.set("#{REDIS_PREFIX}:status", "running")
        started_at = Time.current
        cursor = @redis.get("#{REDIS_PREFIX}:cursor_id") || NULL_UUID
        rows_processed = @redis.get("#{REDIS_PREFIX}:rows_processed").to_i
        batches = 0
        @logger.info("ChatBackfill: starting t0=#{@t0.iso8601} cursor=#{cursor} rows_so_far=#{rows_processed} batch_size=#{@batch_size}")

        loop do
          result = tick

          case result[:status]
          when :paused
            return finish("paused", started_at, result[:rows_processed], batches,
                          "kill-switch flipped — paused at cursor=#{result[:cursor]}, rows=#{result[:rows_processed]}")
          when :done
            return finish("done", started_at, result[:rows_processed], batches,
                          "no more pre-T0 rows; rows_processed=#{result[:rows_processed]} batches=#{batches}")
          when :failed
            @logger.error("ChatBackfill: CH insert failed at cursor=#{result[:cursor]} batch_size=#{result[:batch_size]}: #{result[:last_error]}")
            return Result.new(status: "failed", rows_processed: result[:rows_processed], batches: batches,
                              elapsed_seconds: (Time.current - started_at).to_i)
          when :ok
            batches += 1
            @logger.info("ChatBackfill: progress cursor=#{result[:cursor]} rows=#{result[:rows_processed]} batches=#{batches}") if (batches % LOG_EVERY_N_BATCHES).zero?
            sleep(@sleep_seconds)
          end
        end
      ensure
        BackfillCycleLock.release(@redis, lock_token)
      end
    end

    # TASK-251.58: single-batch operation. Used by both #call (operator-driven loop with sleep)
    # and ChatBackfillCycleWorker (Sidekiq cron with timeboxed deadline; survives container swaps
    # natively, unlike the previous detached-rake pattern which died on every Kamal deploy and
    # required manual setsid re-spawn — observed 4× swap kills during TASK-251.14 backfill window
    # 2026-05-29). Single-writer assumption: this method is idempotent at the cursor level under
    # a single concurrent writer (Redis cursor advances monotonically). It is NOT inherently
    # concurrency-safe — two parallel ticks would both read the same Redis cursor, fetch the same
    # PG batch, and double-insert into the no-engine-dedup CH MergeTree. ChatBackfillCycleWorker
    # enforces single-writer via a cross-process Redis SETNX lock (`:cycle_lock`); the `rake
    # clickhouse:backfill_chat` operator path is single-process by construction.
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

    def finish(status, started_at, rows_processed, batches, message)
      @redis.set("#{REDIS_PREFIX}:status", status)
      @logger.info("ChatBackfill: #{message}")
      Result.new(status: status, rows_processed: rows_processed, batches: batches,
                 elapsed_seconds: (Time.current - started_at).to_i)
    end
  end
end
