# frozen_string_literal: true

# TASK-023: EventSub stream.offline handler.
# TASK-024: IRC PART via Redis pub/sub.
# TASK-025: Finalize Stream record (peak_ccv, avg_ccv, duration_ms).

class StreamOfflineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  IRC_COMMANDS_CHANNEL = "irc:commands"

  def perform(event_data)
    broadcaster_id = event_data["broadcaster_user_id"]
    broadcaster_login = event_data["broadcaster_user_login"]

    Rails.logger.info("StreamOfflineWorker: stream.offline for #{broadcaster_login} (#{broadcaster_id})")

    channel = Channel.find_by(twitch_id: broadcaster_id)
    unless channel
      Rails.logger.warn("StreamOfflineWorker: channel not found for #{broadcaster_id}")
      return
    end

    stream = channel.streams.where(ended_at: nil).order(started_at: :desc).first
    unless stream
      Rails.logger.warn("StreamOfflineWorker: no active stream for #{broadcaster_login}")
      return
    end

    finalize_stream(stream)

    # TASK-024: Tell IrcMonitor to leave this channel's chat
    publish_irc_part(broadcaster_login)

    Rails.logger.info("StreamOfflineWorker: finalized Stream #{stream.id} — peak:#{stream.peak_ccv} avg:#{stream.avg_ccv} duration:#{stream.duration_ms}ms")
  end

  private

  def finalize_stream(stream)
    peak = stream.ccv_snapshots.maximum(:ccv_count) || 0
    avg = stream.ccv_snapshots.average(:ccv_count)&.round || 0
    duration = ((Time.current - stream.started_at) * 1000).to_i

    stream.update!(
      ended_at: Time.current,
      peak_ccv: peak,
      avg_ccv: avg,
      duration_ms: duration
    )
  end

  def publish_irc_part(login)
    return unless login.present?

    redis.publish(IRC_COMMANDS_CHANNEL, { action: "part", channel_login: login }.to_json)
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
