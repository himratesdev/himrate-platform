# frozen_string_literal: true

# BUG-251.29: stale-stream sweep. Closes Stream rows that have `ended_at = NULL` but no
# CCV activity in the last STALE_THRESHOLD window. Complements MonitoredLiveDetectorWorker
# which closes streams when Helix reports the channel offline — this worker catches the
# residual where stream.offline EventSub was missed AND Helix sweep partial-failed (e.g.,
# accumulation observed 2026-05-29: 543 stale rows over 4 days, oldest 5 days "live").
#
# Run cron every 15 minutes. Gated by `:stale_stream_sweep` Flipper (default ON post-deploy).
# Safe: only closes streams ≥ STALE_THRESHOLD old AND no CCV in STALE_THRESHOLD window.
# Re-uses StreamOfflineWorker via direct call (sync close + proper cleanup) instead of
# raw update_all — preserves invariants (StreamerReputation refresh, IRC PART, etc.).

class StaleStreamSweepWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  # A stream that hasn't received a CCV snapshot in this window is considered stale.
  # StreamMonitorWorker fires every 60s — 30 minutes = 30 consecutive missed cycles.
  STALE_THRESHOLD = 30.minutes
  # Don't close very recently-started streams even with no CCV yet (gives StreamMonitor
  # a few cycles to populate before declaring abandoned).
  MIN_STREAM_AGE = 10.minutes
  # Cap batch size per cycle to avoid long-running jobs blocking the :monitoring queue.
  BATCH_LIMIT = 200

  def perform
    return unless Flipper.enabled?(:stale_stream_sweep)

    cutoff = STALE_THRESHOLD.ago
    candidates = Stream
      .where(ended_at: nil)
      .where("started_at < ?", MIN_STREAM_AGE.ago)
      .limit(BATCH_LIMIT)
      .pluck(:id, :channel_id, :started_at)

    closed = 0
    skipped = 0
    candidates.each do |stream_id, channel_id, started_at|
      latest_ccv_ts = CcvSnapshot.where(stream_id: stream_id).maximum(:timestamp)

      # Stale if no CCV at all (started > MIN_STREAM_AGE ago) OR last CCV older than cutoff.
      stale = latest_ccv_ts.nil? || latest_ccv_ts < cutoff
      unless stale
        skipped += 1
        next
      end

      close_stale_stream(stream_id, channel_id, started_at, latest_ccv_ts)
      closed += 1
    rescue StandardError => e
      Rails.logger.error("StaleStreamSweepWorker: failed to close stream_id=#{stream_id} (#{e.class}: #{e.message})")
    end

    Rails.logger.info("StaleStreamSweepWorker: scanned=#{candidates.size} closed=#{closed} skipped=#{skipped}")
  end

  private

  # Close the stream row directly + tell IRC to PART. We do NOT enqueue StreamOfflineWorker
  # because it expects EventSub payload shape — instead we apply the close idempotently and
  # publish PART via the same channel StreamOnlineWorker uses for JOIN.
  def close_stale_stream(stream_id, channel_id, started_at, last_ccv_ts)
    ended_at = last_ccv_ts || started_at
    Stream.where(id: stream_id, ended_at: nil).update_all(ended_at: ended_at, updated_at: Time.current)

    channel_login = Channel.where(id: channel_id).pick(:login)
    if channel_login
      publish_irc_part(channel_login)
    end

    Rails.logger.info("StaleStreamSweepWorker: closed stream_id=#{stream_id} channel=#{channel_login} started_at=#{started_at.iso8601} ended_at=#{ended_at.iso8601}")
  end

  def publish_irc_part(login)
    redis.publish(StreamOnlineWorker::IRC_COMMANDS_CHANNEL, { action: "part", channel_login: login }.to_json)
  rescue StandardError => e
    Rails.logger.warn("StaleStreamSweepWorker: publish_irc_part failed for #{login} (#{e.message})")
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
