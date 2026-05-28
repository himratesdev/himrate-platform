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
      batch_insert(records)         # Postgres — source of truth
      mirror_to_clickhouse(records) # ClickHouse — best-effort dual-write (never raises)
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
    return unless Flipper.enabled?(:chat_writes_clickhouse)

    Clickhouse.client.insert("chat_messages", records.map { |record| clickhouse_row(record) })
  rescue StandardError => e
    Rails.logger.warn("ChatMessageWorker: ClickHouse mirror failed (#{e.message}) — Postgres is source of truth, gap backfilled later")
  end

  # Map a Postgres insert hash (parse_message) to a ClickHouse chat_messages row: nils coalesced to
  # the columns' non-nullable defaults, booleans → UInt8, the raw_tags Hash → a JSON string, and the
  # Time → ClickHouse DateTime64 text. stream_id stays nil → CH NULL; inserted_at is omitted (CH
  # DEFAULT now()).
  def clickhouse_row(rec)
    {
      stream_id: rec[:stream_id],
      channel_login: rec[:channel_login].to_s,
      username: rec[:username].to_s,
      msg_type: rec[:msg_type].to_s,
      subscriber_status: rec[:subscriber_status].to_s,
      user_type: rec[:user_type].to_s,
      is_first_msg: rec[:is_first_msg] ? 1 : 0,
      returning_chatter: rec[:returning_chatter] ? 1 : 0,
      vip: rec[:vip] ? 1 : 0,
      bits_used: rec[:bits_used].to_i,
      display_name: rec[:display_name].to_s,
      badge_info: rec[:badge_info].to_s,
      color: rec[:color].to_s,
      twitch_msg_id: rec[:twitch_msg_id].to_s,
      message_text: rec[:message_text].to_s,
      emotes: rec[:emotes].to_s,
      raw_tags: rec[:raw_tags].is_a?(String) ? rec[:raw_tags] : JSON.generate(rec[:raw_tags] || {}),
      timestamp: rec[:timestamp].utc.strftime("%Y-%m-%d %H:%M:%S.%3N")
    }
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

  def batch_insert(records)
    ChatMessage.insert_all(records)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.error("ChatMessageWorker: batch INSERT failed (#{e.message}), trying individual inserts")
    individual_insert(records)
  end

  def individual_insert(records)
    inserted = 0
    records.each do |record|
      ChatMessage.create!(record)
      inserted += 1
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("ChatMessageWorker: skip invalid record (#{e.message})")
    end
    Rails.logger.info("ChatMessageWorker: individual insert #{inserted}/#{records.size}")
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
