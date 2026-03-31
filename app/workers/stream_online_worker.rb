# frozen_string_literal: true

# TASK-023: EventSub stream.online handler.
# TASK-024: IRC JOIN via Redis pub/sub.
# TASK-025: Create Stream record, stream merge logic, enrich via GQL.

class StreamOnlineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  IRC_COMMANDS_CHANNEL = "irc:commands"
  MERGE_GAP_MINUTES = 30

  def perform(event_data)
    broadcaster_id = event_data["broadcaster_user_id"]
    broadcaster_login = event_data["broadcaster_user_login"]

    Rails.logger.info("StreamOnlineWorker: stream.online for #{broadcaster_login} (#{broadcaster_id})")

    channel = find_or_create_channel(broadcaster_id, broadcaster_login)
    return if active_stream_exists?(channel)

    stream = merge_or_create_stream(channel, event_data)

    # TASK-024: Tell IrcMonitor to join this channel's chat
    publish_irc_join(broadcaster_login)

    Rails.logger.info("StreamOnlineWorker: Stream #{stream.id} for ##{broadcaster_login} (merge: #{stream.merge_status})")
  end

  private

  def find_or_create_channel(twitch_id, login)
    Channel.find_or_create_by!(twitch_id: twitch_id) do |c|
      c.login = login
      c.is_monitored = true
    end
  end

  def active_stream_exists?(channel)
    exists = channel.streams.where(ended_at: nil).exists?
    Rails.logger.info("StreamOnlineWorker: active stream already exists, skipping") if exists
    exists
  end

  def merge_or_create_stream(channel, event_data)
    # EventSub stream.online does NOT contain category_name/title — fetch from GQL first
    metadata = fetch_metadata(channel.login)
    game_name = metadata&.dig(:game_name)
    title = metadata&.dig(:title)
    language = metadata&.dig(:language)

    last_stream = channel.streams.where.not(ended_at: nil).order(ended_at: :desc).first
    if last_stream && last_stream.ended_at > MERGE_GAP_MINUTES.minutes.ago && merge_game_match?(game_name, last_stream.game_name)
      # TASK-033 FR-004: Track part boundaries for TI Divergence detection
      last_ti = TrustIndexHistory.where(stream_id: last_stream.id)
                                 .order(calculated_at: :desc)
                                 .first
      boundary = {
        ended_at: last_stream.ended_at.iso8601,
        ti_score: last_ti&.trust_index_score&.to_f,
        erv_percent: last_ti&.erv_percent&.to_f,
        part_number: last_stream.merged_parts_count
      }
      last_stream.update!(
        ended_at: nil,
        merge_status: "merged",
        merged_parts_count: last_stream.merged_parts_count + 1,
        part_boundaries: (last_stream.part_boundaries || []) + [ boundary ]
      )
      Rails.logger.info("StreamOnlineWorker: merged with previous stream #{last_stream.id} (parts: #{last_stream.merged_parts_count})")
      last_stream
    else
      Stream.create!(
        channel: channel,
        started_at: event_data["started_at"] || Time.current,
        title: title,
        game_name: game_name,
        language: language
      )
    end
  end

  # TASK-033 FR-004: nil game_name fallback — GQL failure should not break merge.
  # Both nil = merge (benefit of doubt for reconnection).
  def merge_game_match?(current_game, previous_game)
    return true if current_game.nil? && previous_game.nil?
    return false if current_game.nil? || previous_game.nil?

    current_game == previous_game
  end

  def fetch_metadata(login)
    Twitch::GqlClient.new.stream_metadata(channel_login: login)
  rescue StandardError => e
    Rails.logger.warn("StreamOnlineWorker: GQL metadata failed (#{e.message})")
    nil
  end

  def publish_irc_join(login)
    return unless login.present?

    redis.publish(IRC_COMMANDS_CHANNEL, { action: "join", channel_login: login }.to_json)
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
