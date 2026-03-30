# frozen_string_literal: true

# TASK-026: Known Bot List + Bloom Filter service.
# Checks usernames against Redis Bloom Filter (RedisBloom) for O(1) lookup.
# Multi-DB cross-reference: 2+ sources → confidence 0.95, 1 → 0.75.
# Fallback to Redis SET if RedisBloom module not available.

class KnownBotService
  BF_KEY_ALL = "known_bots:all"
  BF_KEY_PREFIX = "known_bots:"
  SOURCES = %w[commanderroot twitchinsights twitchbots_info streamscharts truevio].freeze
  BOT_CATEGORIES = %w[view_bot service_bot unknown].freeze

  CONFIDENCE_MULTI = 0.95  # found in 2+ sources
  CONFIDENCE_SINGLE = 0.75 # found in 1 source
  CONFIDENCE_NATIVE = 1.0  # Twitch-marked chatbot

  class Error < StandardError; end

  def initialize
    @use_bloom = detect_bloom_support
    Rails.logger.info("KnownBotService: initialized (bloom=#{@use_bloom})")
  end

  # FR-001: Check single username. O(1).
  def bot?(username)
    name = username.to_s.downcase.strip
    return { bot: false, confidence: 0.0, sources: [] } if name.blank?

    found = exists_in_all?(name)
    return { bot: false, confidence: 0.0, sources: [] } unless found

    # FR-002: Cross-reference for confidence
    sources = find_sources(name)
    confidence = sources.size >= 2 ? CONFIDENCE_MULTI : CONFIDENCE_SINGLE
    { bot: true, confidence: confidence, sources: sources }
  rescue Redis::BaseError => e
    Rails.logger.warn("KnownBotService: Redis error in bot? (#{e.message})")
    { bot: false, confidence: 0.0, sources: [] }
  end

  BATCH_LIMIT = 1000

  # FR-003: Batch check. Returns Hash{username => result}. Max 1000 per call.
  def check_batch(usernames)
    names = usernames.map { |u| u.to_s.downcase.strip }.reject(&:blank?).first(BATCH_LIMIT)
    return {} if names.empty?

    results = batch_exists_all(names)
    output = {}

    names.each_with_index do |name, i|
      if results[i]
        sources = find_sources(name)
        confidence = sources.size >= 2 ? CONFIDENCE_MULTI : CONFIDENCE_SINGLE
        output[name] = { bot: true, confidence: confidence, sources: sources }
      else
        output[name] = { bot: false, confidence: 0.0, sources: [] }
      end
    end

    output
  rescue Redis::BaseError => e
    Rails.logger.warn("KnownBotService: Redis error in check_batch (#{e.message})")
    usernames.each_with_object({}) { |u, h| h[u.to_s.downcase] = { bot: false, confidence: 0.0, sources: [] } }
  end

  # FR-009: Add bot to internal DB + Bloom Filter.
  def add_bot(username, source, confidence, category: "unknown")
    name = username.to_s.downcase.strip
    return :invalid if name.blank? || !SOURCES.include?(source)

    record = KnownBotList.find_or_initialize_by(username: name, source: source)
    if record.new_record?
      record.assign_attributes(confidence: confidence, bot_category: category, added_at: Time.current)
      record.save!
      add_to_filter(BF_KEY_ALL, name)
      add_to_filter("#{BF_KEY_PREFIX}#{source}", name)
      :ok
    else
      record.update!(confidence: [ record.confidence, confidence ].max, last_seen_at: Time.current)
      :exists
    end
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("KnownBotService: add_bot failed (#{e.message})")
    :error
  end

  # FR-013: Add Twitch-native chatbot (from CommunityTab "chatbots" role).
  # Confidence 1.0 — Twitch itself marked the account.
  def add_twitch_native_bot(username)
    add_bot(username, "truevio", CONFIDENCE_NATIVE, category: "service_bot")
  end

  # FR-014: Update last_seen_at when bot is seen in real chat.
  def touch_bot(username)
    name = username.to_s.downcase.strip
    KnownBotList.where(username: name).update_all(last_seen_at: Time.current)
  end

  # FR-008: Rebuild all Bloom Filters from source data.
  def rebuild_filters(source_data)
    # source_data = { "commanderroot" => ["user1", ...], "twitchinsights" => [...], ... }
    all_usernames = []

    source_data.each do |source, usernames|
      key_new = "#{BF_KEY_PREFIX}#{source}:new"
      reserve_filter(key_new, usernames.size)
      batch_add(key_new, usernames)
      redis.rename(key_new, "#{BF_KEY_PREFIX}#{source}")
      all_usernames.concat(usernames)
    end

    # Combined filter
    all_unique = all_usernames.uniq
    key_new = "#{BF_KEY_ALL}:new"
    reserve_filter(key_new, all_unique.size)
    batch_add(key_new, all_unique)
    redis.rename(key_new, BF_KEY_ALL)

    Rails.logger.info("KnownBotService: rebuilt filters — #{all_unique.size} total, #{source_data.map { |s, u| "#{s}:#{u.size}" }.join(", ")}")
    all_unique.size
  end

  # Stats for monitoring.
  def stats
    {
      bloom_support: @use_bloom,
      total_db: KnownBotList.count,
      per_source: KnownBotList.group(:source).count,
      per_category: KnownBotList.group(:bot_category).count
    }
  end

  private

  # === Bloom Filter / SET abstraction ===

  def detect_bloom_support
    redis.call("BF.EXISTS", "known_bots:test_support", "test")
    true
  rescue Redis::CommandError
    Rails.logger.warn("KnownBotService: RedisBloom not available, using SET fallback")
    false
  rescue Redis::BaseError
    false
  end

  def exists_in_all?(username)
    if @use_bloom
      redis.call("BF.EXISTS", BF_KEY_ALL, username) == 1
    else
      redis.sismember(BF_KEY_ALL, username)
    end
  end

  def batch_exists_all(usernames)
    if @use_bloom
      redis.call("BF.MEXISTS", BF_KEY_ALL, *usernames).map { |r| r == 1 }
    else
      redis.pipelined { |p| usernames.each { |u| p.sismember(BF_KEY_ALL, u) } }
    end
  end

  def find_sources(username)
    SOURCES.select do |source|
      key = "#{BF_KEY_PREFIX}#{source}"
      if @use_bloom
        redis.call("BF.EXISTS", key, username) == 1
      else
        redis.sismember(key, username)
      end
    rescue Redis::CommandError
      false
    end
  end

  def add_to_filter(key, username)
    if @use_bloom
      redis.call("BF.ADD", key, username)
    else
      redis.sadd(key, username)
    end
  end

  def reserve_filter(key, capacity)
    redis.del(key)
    if @use_bloom
      error_rate = 0.001 # FPR <0.1%
      redis.call("BF.RESERVE", key, error_rate, [ capacity * 1.2, 1000 ].max.to_i)
    end
    # SET doesn't need reservation
  end

  def batch_add(key, usernames)
    usernames.each_slice(10_000) do |batch|
      if @use_bloom
        redis.call("BF.MADD", key, *batch)
      else
        redis.sadd(key, batch)
      end
    end
  end

  def redis
    @redis ||= begin
      r = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
      r.ping
      r
    rescue Redis::CannotConnectError => e
      Rails.logger.warn("KnownBotService: Redis unavailable (#{e.message})")
      Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
