# frozen_string_literal: true

# TASK-024: Batch insert chat messages from Redis queue into ClickHouse.
# Reads from Redis list `irc:chat_messages`, inserts in batches.
# TASK-251.5: cron-driven (every minute). Drains the queue in a loop until empty or
# MAX_RUNTIME_SECONDS, then exits — sidekiq-cron re-runs it next minute.
# PR 1e-A (2026-05-31): post-CH-cutover, ClickHouse is the SoT. PG INSERT path dropped
# (Postgres chat_messages will be removed in PR 1e-B). CH write is no longer best-effort —
# it must succeed or the batch re-queues. The :chat_writes_clickhouse flag and the dual-write
# mirror gating are gone with the cutover.

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

  # Insert one drained batch into ClickHouse. drain_redis_queue already removed the batch from
  # Redis, so on any failure re-queue the raw batch before re-raising — otherwise the batch
  # would be lost (CR nit-1, original PG behaviour preserved). Sidekiq retry then picks it up.
  def insert_batch(raw)
    records = raw.filter_map { |json| parse_message(json) }
    write_to_clickhouse(records) if records.any?
    records.size
  rescue StandardError => e
    requeue(raw)
    raise e
  end

  # PR 1e-A: primary write path (was `mirror_to_clickhouse` under the dual-write era). CH is now
  # the SoT for chat — no `best_effort: true`, no flag gate, no silent rescue. A CH outage MUST
  # surface as a worker exception so the batch returns to Redis and Sidekiq retries (matches the
  # pre-cutover PG behaviour). Row mapping still delegated to Clickhouse::ChatRow.from_pg —
  # the method name is kept for the back-compat row shape it produces (rename to from_record
  # in a follow-up touch-up; out of scope here).
  def write_to_clickhouse(records)
    Clickhouse.client.insert(
      "chat_messages",
      records.map { |record| Clickhouse::ChatRow.from_pg(record) }
    )
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
