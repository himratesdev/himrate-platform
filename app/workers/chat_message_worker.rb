# frozen_string_literal: true

# TASK-024: Batch insert chat messages from Redis queue into PostgreSQL.
# Reads from Redis list `irc:chat_messages`, inserts in batches via insert_all.
# TASK-251.5: cron-driven (every minute). Drains the queue in a loop until empty or
# MAX_RUNTIME_SECONDS, then exits — sidekiq-cron re-runs it next minute. (Replaces the old
# self-reschedule, which was never bootstrapped → the queue never drained → ChatMessage=0.)

class ChatMessageWorker
  include Sidekiq::Job
  sidekiq_options queue: :chat, retry: 3

  REDIS_QUEUE_KEY = "irc:chat_messages"
  BATCH_SIZE = 500
  MAX_RUNTIME_SECONDS = 50 # drain loop budget; < 60s cron cadence → no overlapping runs

  def perform
    deadline = Time.current + MAX_RUNTIME_SECONDS
    total = 0

    loop do
      raw = drain_redis_queue
      break if raw.empty?

      total += insert_batch(raw)
      break if Time.current >= deadline
    end

    Rails.logger.info("ChatMessageWorker: inserted #{total} messages") if total.positive?
  end

  private

  # Insert one drained batch. drain_redis_queue already removed it from Redis, so on an
  # unexpected (e.g. connection-level) failure re-queue the raw batch before re-raising —
  # otherwise the batch would be lost (CR nit-1). StatementInvalid is handled inside
  # batch_insert (per-record), so only connection/unexpected errors reach the rescue here.
  def insert_batch(raw)
    records = raw.filter_map { |json| parse_message(json) }
    if records.any?
      persisted = batch_insert(records) # Postgres — source of truth; returns rows actually written
      mirror_to_clickhouse(persisted)   # ClickHouse — best-effort mirror of exactly what PG wrote
    end
    records.size
  rescue StandardError => e
    requeue(raw)
    raise e
  end

  # TASK-251.14b: mirror the just-inserted batch into ClickHouse (the analytics store being migrated
  # to). Postgres stays the source of truth; gated by :chat_writes_clickhouse (OFF until ingest-parity
  # is validated per env). NEVER raises — a CH failure must not requeue the batch (that would
  # double-write Postgres) nor block ingest; the gap is closed by the backfill (PR 1c).
  def mirror_to_clickhouse(records)
    return if records.empty?
    return unless Flipper.enabled?(:chat_writes_clickhouse)

    # best_effort: true → short timeout, no retry — a CH outage must not stall the drain loop.
    # Row mapping delegated to Clickhouse::ChatRow (TASK-251.14c): single source of truth shared
    # with the historical backfill so live mirror + backfill produce byte-identical rows.
    Clickhouse.client.insert("chat_messages", records.map { |record| Clickhouse::ChatRow.from_pg(record) }, best_effort: true)
  rescue StandardError => e
    # Log the error class only — the message can echo CH response-body fragments.
    Rails.logger.warn("ChatMessageWorker: ClickHouse mirror failed (#{e.class}) — Postgres is source of truth, gap backfilled later")
  end

  # Restore a drained batch to the tail (oldest-first FIFO preserved) so Sidekiq retry
  # re-processes it. Best-effort: if Redis itself is down the batch is already lost.
  def requeue(raw)
    redis.rpush(REDIS_QUEUE_KEY, *raw) if raw.any?
  rescue Redis::BaseError
    nil
  end

  def drain_redis_queue
    results = redis.multi do |tx|
      tx.lrange(REDIS_QUEUE_KEY, -BATCH_SIZE, -1)
      tx.ltrim(REDIS_QUEUE_KEY, 0, -(BATCH_SIZE + 1))
    end

    # lrange returns the batch, ltrim removes it atomically
    results&.first || []
  end

  def parse_message(json_str)
    data = JSON.parse(json_str)

    # Resolve stream_id from channel_login if not provided
    stream_id = data["stream_id"] || resolve_stream_id(data["channel_login"])

    {
      stream_id: stream_id,
      channel_login: data["channel_login"],
      username: data["username"].to_s.truncate(255),
      message_text: data["message_text"],
      msg_type: data["msg_type"] || "privmsg",
      display_name: data["display_name"]&.truncate(255),
      subscriber_status: data["subscriber_status"]&.truncate(10),
      badge_info: data["badge_info"]&.truncate(255),
      is_first_msg: data["is_first_msg"] || false,
      returning_chatter: data["returning_chatter"] || false,
      emotes: data["emotes"],
      user_type: data["user_type"]&.truncate(10),
      vip: data["vip"] || false,
      color: data["color"]&.truncate(7),
      bits_used: data["bits_used"].to_i,
      twitch_msg_id: data["twitch_msg_id"]&.truncate(255),
      raw_tags: data["raw_tags"] || {},
      timestamp: parse_timestamp(data["timestamp"])
    }
  rescue JSON::ParserError => e
    Rails.logger.warn("ChatMessageWorker: invalid JSON (#{e.message})")
    nil
  end

  # Returns the records actually persisted to Postgres so the ClickHouse mirror reflects exactly what
  # PG holds (no CH-superset divergence). Bulk path writes all; fallback returns the written subset.
  def batch_insert(records)
    ChatMessage.insert_all(records)
    records
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error("ChatMessageWorker: batch INSERT failed (#{e.message}), trying individual inserts")
    individual_insert(records)
  end

  def individual_insert(records)
    persisted = records.each_with_object([]) do |record, kept|
      ChatMessage.create!(record)
      kept << record
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("ChatMessageWorker: skip invalid record (#{e.message})")
    end
    Rails.logger.info("ChatMessageWorker: individual insert #{persisted.size}/#{records.size}")
    persisted
  end

  def resolve_stream_id(channel_login)
    return nil unless channel_login

    # Find active stream for this channel
    channel = Channel.find_by(login: channel_login)
    return nil unless channel

    channel.streams.where(ended_at: nil).order(started_at: :desc).pick(:id)
  end

  def parse_timestamp(value)
    return Time.current unless value

    Time.parse(value)
  rescue ArgumentError
    Time.current
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
