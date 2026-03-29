# frozen_string_literal: true

# TASK-023: EventSub stream.online handler.
# TASK-024: Sends JOIN command to IrcMonitor via Redis pub/sub.
# Real stream session creation: TASK-025 (Stream Monitor).

class StreamOnlineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  IRC_COMMANDS_CHANNEL = "irc:commands"

  def perform(event_data)
    broadcaster_id = event_data["broadcaster_user_id"]
    broadcaster_login = event_data["broadcaster_user_login"]

    Rails.logger.info("StreamOnlineWorker: stream.online for #{broadcaster_login} (#{broadcaster_id})")

    # TASK-024: Tell IrcMonitor to join this channel's chat
    if broadcaster_login.present?
      redis.publish(IRC_COMMANDS_CHANNEL, {
        action: "join",
        channel_login: broadcaster_login
      }.to_json)
      Rails.logger.info("StreamOnlineWorker: published IRC join for ##{broadcaster_login}")
    end
  end

  private

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
