# frozen_string_literal: true

# TASK-025: Channel Monitoring Orchestrator — periodic polling.
# Tier 1 (every cycle, 60s): CCV + chatters count → snapshots.
# Tier 2 (every 5th cycle, ~5min): ChatRoomState, Predictions, Polls, HypeTrain.
# Stateless: reads active streams from DB each cycle.

class StreamMonitorWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  CYCLE_INTERVAL = 60 # seconds
  TIER2_EVERY = 5     # every 5th cycle = ~5 minutes
  GQL_BATCH_SIZE = 35
  REDIS_CYCLE_KEY = "monitor:cycle_count"

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    active_streams = Stream.includes(:channel).where(ended_at: nil)
    return schedule_next if active_streams.empty?

    cycle = increment_cycle

    # Tier 1: CCV + chatters (every cycle)
    poll_tier1(active_streams)

    # Tier 2: ChatRoomState + Predictions/Polls/HypeTrain (every 5th cycle)
    poll_tier2(active_streams) if (cycle % TIER2_EVERY).zero?

    Rails.logger.info("StreamMonitorWorker: cycle #{cycle}, #{active_streams.size} streams")
    schedule_next
  end

  private

  # === Tier 1: CCV + Chatters ===

  def poll_tier1(streams)
    streams.each_slice(GQL_BATCH_SIZE) do |batch|
      logins = batch.map { |s| s.channel.login }

      # Batch GQL for CCV
      ccv_data = fetch_ccv_batch(logins)

      # Chatters count for each
      chatters_data = fetch_chatters_batch(logins)

      batch.each do |stream|
        login = stream.channel.login
        ccv = ccv_data[login]
        chatters = chatters_data[login]

        save_ccv_snapshot(stream, ccv) if ccv
        save_chatters_snapshot(stream, ccv, chatters) if chatters
      end
    end
  end

  def fetch_ccv_batch(logins)
    result = {}
    logins.each do |login|
      data = gql.stream_metadata(channel_login: login)
      if data
        result[login] = data[:viewers_count].to_i
      else
        # Helix fallback
        helix_data = helix.get_streams(user_logins: [ login ])&.first
        result[login] = helix_data&.dig("viewer_count").to_i if helix_data
      end
    end
    result
  rescue Twitch::GqlClient::Error => e
    Rails.logger.warn("StreamMonitorWorker: GQL batch failed (#{e.message}), trying Helix fallback")
    fetch_ccv_helix_fallback(logins)
  end

  def fetch_ccv_helix_fallback(logins)
    result = {}
    logins.each_slice(100) do |batch|
      streams = helix.get_streams(user_logins: batch) || []
      streams.each do |s|
        login = s["user_login"]&.downcase
        result[login] = s["viewer_count"].to_i if login
      end
    end
    result
  end

  def fetch_chatters_batch(logins)
    result = {}
    logins.each do |login|
      count = gql.channel_chatters_count(channel_login: login)
      result[login] = count.to_i if count
    end
    result
  rescue Twitch::GqlClient::Error => e
    Rails.logger.warn("StreamMonitorWorker: chatters GQL failed (#{e.message})")
    {}
  end

  def save_ccv_snapshot(stream, ccv_count)
    CcvSnapshot.create!(
      stream: stream,
      timestamp: Time.current,
      ccv_count: ccv_count
    )
  end

  def save_chatters_snapshot(stream, ccv_count, chatters_count)
    auth_ratio = ccv_count.to_i > 0 ? chatters_count.to_f / ccv_count : nil

    ChattersSnapshot.create!(
      stream: stream,
      timestamp: Time.current,
      unique_chatters_count: chatters_count,
      total_messages_count: 0,
      auth_ratio: auth_ratio
    )
  end

  # === Tier 2: ChatRoomState + Predictions/Polls/HypeTrain ===

  def poll_tier2(streams)
    streams.each do |stream|
      login = stream.channel.login

      update_chat_room_state(stream.channel, login)
      poll_predictions(stream, login)
      poll_polls(stream, login)
      poll_hype_train(stream, login)
    end
  end

  def update_chat_room_state(channel, login)
    data = gql.chat_room_state(channel_login: login)
    return unless data

    config = channel.channel_protection_config || channel.build_channel_protection_config
    config.update!(
      followers_only_duration_min: data[:followers_only_duration_minutes],
      slow_mode_seconds: data[:slow_mode_duration_seconds],
      emote_only_enabled: data[:emote_only_mode] || false,
      subs_only_enabled: data[:subscriber_only_mode] || false,
      last_checked_at: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("StreamMonitorWorker: ChatRoomState save failed for #{login} (#{e.message})")
  end

  def poll_predictions(stream, login)
    data = gql.predictions(channel_login: login)
    return unless data

    ccv = stream.ccv_snapshots.order(timestamp: :desc).pick(:ccv_count) || 0
    ratio = ccv > 0 ? data[:total_users].to_f / ccv : nil

    PredictionsPoll.create!(
      stream: stream,
      event_type: "prediction",
      participants_count: data[:total_users],
      ccv_at_time: ccv,
      participation_ratio: ratio,
      timestamp: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("StreamMonitorWorker: Prediction save failed (#{e.message})")
  end

  def poll_polls(stream, login)
    data = gql.polls(channel_login: login)
    return unless data

    ccv = stream.ccv_snapshots.order(timestamp: :desc).pick(:ccv_count) || 0
    ratio = ccv > 0 ? data[:total_voters].to_f / ccv : nil

    PredictionsPoll.create!(
      stream: stream,
      event_type: "poll",
      participants_count: data[:total_voters],
      ccv_at_time: ccv,
      participation_ratio: ratio,
      timestamp: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("StreamMonitorWorker: Poll save failed (#{e.message})")
  end

  def poll_hype_train(stream, login)
    data = gql.hype_train(channel_login: login)
    return unless data

    ccv = stream.ccv_snapshots.order(timestamp: :desc).pick(:ccv_count) || 0
    ratio = ccv > 0 ? data[:conductors_count].to_f / ccv : nil

    PredictionsPoll.create!(
      stream: stream,
      event_type: "hype_train",
      participants_count: data[:conductors_count],
      ccv_at_time: ccv,
      participation_ratio: ratio,
      timestamp: Time.current
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("StreamMonitorWorker: HypeTrain save failed (#{e.message})")
  end

  # === Scheduling ===

  def increment_cycle
    redis.incr(REDIS_CYCLE_KEY).to_i
  end

  def schedule_next
    self.class.perform_in(CYCLE_INTERVAL)
  end

  # === Clients ===

  def gql
    @gql ||= Twitch::GqlClient.new
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
