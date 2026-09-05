# frozen_string_literal: true

module Farm
  # EPIC FARM T-F1: drain the capture pool's Redis list (`farm:capture:chat_messages`, filled by
  # bin/irc_capture shards) into ClickHouse `capture_chat_messages`. Cron every minute; drains in a
  # loop for ≤50s then exits (same contract as ChatMessageWorker).
  #
  # Deliberately NO per-message PostgreSQL lookups: the capture set has no Channel/Stream rows,
  # `game_id` comes from ONE HGETALL of the capture set per run (login → game_id), and rows go
  # through the shared Clickhouse::ChatRow mapper minus `stream_id`.
  #
  # Batch shaping (CR iter-1 S3): at the design load (~230 msg/s) the list is never empty between
  # two LRANGEs, so a naive "loop until empty" would issue hundreds of tiny INSERTs per run (CH part
  # churn → `too many parts`) and pin a compute_tier2 thread for the whole 50s. After a partial
  # batch the worker pauses ACCUMULATE_SECONDS so the next LRANGE actually gets a full batch —
  # ≈ 10 INSERTs of ~1–2k rows per run instead of hundreds.
  #
  # Backlog visibility (CR iter-1 S4): CH is the sole store for this chat; if it is down the list
  # grows in the shared Sidekiq Redis (~0.5 GB/h at design load). Every run logs the queue length
  # and WARNs above BACKLOG_WARN so an outage is visible before Redis memory is.
  #
  # Not flag-gated on purpose: when :farm_capture is paused the pool stops producing, and the
  # drain simply empties whatever is left instead of leaving rows to grow Redis memory.
  class CaptureChatDrainWorker
    include Sidekiq::Job
    sidekiq_options queue: :chat, retry: 3

    QUEUE_KEY = Farm::CaptureSet::QUEUE_KEY
    TABLE = "capture_chat_messages"
    BATCH_SIZE = 2000
    MAX_RUNTIME_SECONDS = 50 # < 60s cron cadence → no overlapping runs
    ACCUMULATE_SECONDS = 5   # pause after a partial batch so the next one fills up
    BACKLOG_WARN = 100_000   # ≈ 7 min of design-load ingest stuck in Redis → CH is probably down

    def perform
      deadline = Time.current + MAX_RUNTIME_SECONDS
      backlog = redis.llen(QUEUE_KEY)
      Rails.logger.warn("Farm::CaptureChatDrainWorker: backlog=#{backlog} above #{BACKLOG_WARN} — ClickHouse ingest lagging or down") if backlog > BACKLOG_WARN

      game_ids = nil
      total = 0
      loop do
        raw = drain_redis_queue
        break if raw.empty?

        game_ids ||= Farm::CaptureSet.new.game_ids # one HGETALL per run, only when there is work
        total += insert_batch(raw, game_ids)
        remaining = deadline - Time.current
        break if remaining <= 0

        pause([ ACCUMULATE_SECONDS, remaining ].min) if raw.size < BATCH_SIZE
      end

      Rails.logger.info("Farm::CaptureChatDrainWorker: inserted #{total} messages (backlog at start=#{backlog})") if total.positive? || backlog.positive?
    end

    private

    # On any failure re-queue the drained batch before re-raising so nothing is lost; Sidekiq
    # retry picks it up (CH is the sole store for this chat — an outage must surface, not swallow).
    def insert_batch(raw, game_ids)
      rows = raw.filter_map { |json| build_row(json, game_ids) }
      Clickhouse.client.insert(TABLE, rows) if rows.any?
      rows.size
    rescue StandardError => e
      requeue(raw)
      raise e
    end

    # A single malformed entry must never poison the batch into an endless requeue→raise loop
    # (CR iter-1 N5): any per-row failure is logged and the row dropped.
    def build_row(json, game_ids)
      data = JSON.parse(json)
      row = Clickhouse::ChatRow.from_pg(data.merge("timestamp" => parse_timestamp(data["timestamp"])))
      row.delete(:stream_id) # capture channels have no Stream rows; the table has no such column
      row.merge(game_id: game_ids[data["channel_login"].to_s].to_s)
    rescue StandardError => e
      Rails.logger.warn("Farm::CaptureChatDrainWorker: dropping malformed entry (#{e.class}: #{e.message.truncate(120)})")
      nil
    end

    def parse_timestamp(value)
      return Time.current if value.blank?

      Time.zone.parse(value.to_s) || Time.current
    end

    def pause(seconds)
      sleep(seconds) if seconds.positive?
    end

    # Restore a drained batch to the tail (oldest-first FIFO preserved). Best-effort: if Redis
    # itself is down the batch is already lost.
    def requeue(raw)
      redis.rpush(QUEUE_KEY, *raw) if raw.any?
    rescue Redis::BaseError
      nil
    end

    def drain_redis_queue
      results = redis.multi do |tx|
        tx.lrange(QUEUE_KEY, -BATCH_SIZE, -1)
        tx.ltrim(QUEUE_KEY, 0, -(BATCH_SIZE + 1))
      end
      results&.first || []
    end

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
