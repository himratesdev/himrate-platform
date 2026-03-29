# frozen_string_literal: true

# TASK-024: Batch insert chat messages from Redis queue into PostgreSQL.
# Reads from Redis list `irc:chat_messages`, inserts in batches via insert_all.
# Self-scheduling: enqueues itself again after processing.

class ChatMessageWorker
  include Sidekiq::Job
  sidekiq_options queue: :chat, retry: 3

  REDIS_QUEUE_KEY = "irc:chat_messages"
  BATCH_SIZE = 500
  SCHEDULE_INTERVAL = 5 # seconds

  def perform
    messages = drain_redis_queue
    return schedule_next if messages.empty?

    records = messages.filter_map { |json| parse_message(json) }
    batch_insert(records) if records.any?

    Rails.logger.info("ChatMessageWorker: inserted #{records.size}/#{messages.size} messages")
    schedule_next
  end

  private

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

  def schedule_next
    self.class.perform_in(SCHEDULE_INTERVAL)
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
