# frozen_string_literal: true

module Farm
  # EPIC FARM T-F1: drain the capture pool's Redis list (`farm:capture:chat_messages`, filled by
  # bin/irc_capture shards) into ClickHouse `capture_chat_messages`. Cron every minute; drains in a
  # loop for ≤50s then exits (same contract as ChatMessageWorker).
  #
  # Deliberately NO per-message PostgreSQL lookups: the capture set has no Channel/Stream rows,
  # `game_id` comes from ONE HGETALL of the capture set per run (login → game_id), and rows go
  # through the shared Clickhouse::ChatRow mapper minus `stream_id`. At the design load
  # (~230 msg/s, INGEST-EXPANSION-DESIGN §5.3) that is ~14k rows/min in ≤7 CH inserts.
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

    def perform
      deadline = Time.current + MAX_RUNTIME_SECONDS
      game_ids = nil
      total = 0

      loop do
        raw = drain_redis_queue
        break if raw.empty?

        game_ids ||= Farm::CaptureSet.new.game_ids # one HGETALL per run, only when there is work
        total += insert_batch(raw, game_ids)
        break if Time.current >= deadline
      end

      Rails.logger.info("Farm::CaptureChatDrainWorker: inserted #{total} messages") if total.positive?
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

    def build_row(json, game_ids)
      data = JSON.parse(json)
      row = Clickhouse::ChatRow.from_pg(data.merge("timestamp" => parse_timestamp(data["timestamp"])))
      row.delete(:stream_id) # capture channels have no Stream rows; the table has no such column
      row.merge(game_id: game_ids[data["channel_login"].to_s].to_s)
    rescue JSON::ParserError => e
      Rails.logger.warn("Farm::CaptureChatDrainWorker: invalid JSON (#{e.message})")
      nil
    end

    def parse_timestamp(value)
      return Time.current if value.blank?

      Time.zone.parse(value.to_s) || Time.current
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
