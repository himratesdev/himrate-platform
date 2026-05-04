# frozen_string_literal: true

# TASK-023: EventSub stream.offline handler.
# TASK-024: IRC PART via Redis pub/sub.
# TASK-025: Finalize Stream record (peak_ccv, avg_ccv, duration_ms).
# TASK-027: Trigger BotScoringWorker for per-user bot scoring.

class StreamOfflineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  IRC_COMMANDS_CHANNEL = "irc:commands"

  # TASK-085 FR-020 (ADR-085 D-8a): heuristic threshold для interrupted_at detection.
  # Override via SignalConfiguration row (signal_type='stream_monitor', category='default',
  # param_name='interrupted_threshold_seconds').
  INTERRUPTED_THRESHOLD_DEFAULT_SEC = 600

  def perform(event_data, source = "eventsub")
    broadcaster_id = event_data["broadcaster_user_id"]
    broadcaster_login = event_data["broadcaster_user_login"]

    Rails.logger.info(
      "StreamOfflineWorker: stream.offline for #{broadcaster_login} (#{broadcaster_id}) source:#{source}"
    )

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

    finalize_stream(stream, source: source)

    # TASK-024: Tell IrcMonitor to leave this channel's chat
    publish_irc_part(broadcaster_login)

    # TASK-027: Trigger per-user bot scoring
    BotScoringWorker.perform_async(stream.id)

    # TASK-033 FR-001: Trigger post-stream pipeline (report, notifications, HS, Rating)
    PostStreamWorker.perform_async(stream.id)

    Rails.logger.info(
      "StreamOfflineWorker: finalized Stream #{stream.id} — peak:#{stream.peak_ccv} " \
      "avg:#{stream.avg_ccv} duration:#{stream.duration_ms}ms source:#{source} " \
      "interrupted:#{stream.interrupted_at.present?}"
    )
  end

  private

  # TASK-085 FR-020 (ADR-085 D-8a): set interrupted_at если last_ccv_snapshot stale beyond threshold
  # (heuristic detection ungraceful end). Log includes source field for forensic debugging.
  def finalize_stream(stream, source:)
    peak = stream.ccv_snapshots.maximum(:ccv_count) || 0
    avg = stream.ccv_snapshots.average(:ccv_count)&.round || 0
    duration = ((Time.current - stream.started_at) * 1000).to_i
    interrupted_at = compute_interrupted_at(stream)

    stream.update!(
      ended_at: Time.current,
      peak_ccv: peak,
      avg_ccv: avg,
      duration_ms: duration,
      interrupted_at: interrupted_at
    )

    return unless interrupted_at

    last_ccv = stream.ccv_snapshots.order(timestamp: :desc).first
    lag_seconds = last_ccv ? (Time.current - last_ccv.timestamp).to_i : nil
    Rails.logger.info(
      "StreamOfflineWorker: stream #{stream.id} marked interrupted_at=#{interrupted_at.iso8601} " \
      "source=#{source} last_ccv_lag=#{lag_seconds}s"
    )
  end

  def compute_interrupted_at(stream)
    last_ccv = stream.ccv_snapshots.order(timestamp: :desc).first
    return nil unless last_ccv

    threshold = interrupted_threshold_seconds
    return nil if (Time.current - last_ccv.timestamp) <= threshold

    Time.current
  end

  def interrupted_threshold_seconds
    SignalConfiguration.value_for("stream_monitor", "default", "interrupted_threshold_seconds").to_i
  rescue SignalConfiguration::ConfigurationMissing
    INTERRUPTED_THRESHOLD_DEFAULT_SEC
  end

  def publish_irc_part(login)
    return unless login.present?

    redis.publish(IRC_COMMANDS_CHANNEL, { action: "part", channel_login: login }.to_json)
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
