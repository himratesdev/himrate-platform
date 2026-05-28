# frozen_string_literal: true

module Clickhouse
  # TASK-251.14c: backfill historical Postgres chat_messages into ClickHouse up to a T0 watermark
  # (the timestamp at which the live dual-write was enabled per env). Post-T0 rows are already
  # covered by the live mirror (ChatMessageWorker#mirror_to_clickhouse, PR 1b); the backfill closes
  # the historical gap so signals can read EVERYTHING from CH after the read-migration (PR 1d).
  #
  # Operator-invoked via `rake clickhouse:backfill_chat[t0_iso,batch_size,sleep_seconds]`. Idempotent
  # + resumable: cursor stored in Redis (AOF-durable). Re-running picks up where it left off.
  # Kill-switch: Flipper flag :chat_backfill_running. Flip OFF → loop exits cleanly after the current
  # batch (cursor preserved). Failure path: CH error → log + status=failed + exit WITHOUT advancing
  # the cursor (operator inspects, then re-runs to resume from the same batch).
  #
  # Cursor is the Postgres UUID PK ordered ascending (id > cursor). UUID PK index gives an
  # efficient range scan even on the 13.6M-row table; the `timestamp < T0` filter discards the small
  # tail of post-T0 rows scattered through the id range.
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
      @t0 = t0.is_a?(Time) ? t0 : Time.parse(t0)
      @batch_size = batch_size
      @sleep_seconds = sleep_seconds
      @redis = redis || Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      @client = client || Clickhouse.client
      @logger = logger
    end

    def call
      @redis.set("#{REDIS_PREFIX}:t0", @t0.iso8601)
      @redis.set("#{REDIS_PREFIX}:status", "running")
      cursor = @redis.get("#{REDIS_PREFIX}:cursor_id") || NULL_UUID
      rows_processed = @redis.get("#{REDIS_PREFIX}:rows_processed").to_i
      batches = 0
      started_at = Time.current
      @logger.info("ChatBackfill: starting t0=#{@t0.iso8601} cursor=#{cursor} rows_so_far=#{rows_processed} batch_size=#{@batch_size}")

      loop do
        unless Flipper.enabled?(:chat_backfill_running)
          return finish("paused", started_at, rows_processed, batches,
                        "kill-switch flipped — paused at cursor=#{cursor}, rows=#{rows_processed}")
        end

        batch = fetch_batch(cursor)
        return finish("done", started_at, rows_processed, batches,
                      "no more pre-T0 rows; rows_processed=#{rows_processed} batches=#{batches}") if batch.empty?

        rows = batch.map { |record| ChatRow.from_pg(record.attributes) }

        begin
          @client.insert("chat_messages", rows)
        rescue Clickhouse::Error => e
          @redis.set("#{REDIS_PREFIX}:status", "failed")
          @redis.set("#{REDIS_PREFIX}:last_error", "#{e.class}: #{e.message.truncate(500)}")
          @logger.error("ChatBackfill: CH insert failed at cursor=#{cursor} batch_size=#{batch.size}: #{e.class}: #{e.message.truncate(200)}")
          return Result.new(status: "failed", rows_processed: rows_processed, batches: batches,
                            elapsed_seconds: (Time.current - started_at).to_i)
        end

        cursor = batch.last.id
        rows_processed += batch.size
        batches += 1
        @redis.set("#{REDIS_PREFIX}:cursor_id", cursor)
        @redis.set("#{REDIS_PREFIX}:rows_processed", rows_processed.to_s)

        @logger.info("ChatBackfill: progress cursor=#{cursor} rows=#{rows_processed} batches=#{batches}") if (batches % LOG_EVERY_N_BATCHES).zero?

        sleep(@sleep_seconds) if @sleep_seconds.positive?
      end
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
