# frozen_string_literal: true

# BUG-251.29: stale-stream sweep. Enqueues StreamOfflineWorker for Stream rows with
# ended_at NULL but no CCV activity in the last STALE_THRESHOLD window. Complements
# MonitoredLiveDetectorWorker (Helix-based offline detection) for the residual case where
# stream.offline EventSub was missed AND Helix sweep partial-failed (e.g., accumulation
# observed 2026-05-29: 543 stale rows over 4 days, oldest 5 days "live").
#
# Run cron every 15 minutes. Gated by `:stale_stream_sweep` HOOK_FLAG (OFF by default —
# enabled per-env post-deploy after dry-run review).
#
# CR-iter1 MF-1: closure goes through StreamOfflineWorker (same payload shape used by
# MonitoredLiveDetectorWorker line 119-122 "live_detector" source) so finalize_stream
# populates peak_ccv / avg_ccv / duration_ms, interrupted_at evaluation runs, and
# BotScoringWorker + PostStreamWorker are enqueued. StreamOfflineWorker's idempotency guards
# (stream_offline_worker.rb:33-37) make concurrent close paths (EventSub / live_detector /
# stale_sweep) safe to overlap.

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
  OFFLINE_SOURCE = "stale_sweep"

  def perform
    return unless Flipper.enabled?(:stale_stream_sweep)

    cutoff = STALE_THRESHOLD.ago
    # CR-iter1 SF-2: ORDER BY started_at ASC so the oldest backlog clears first (otherwise
    # an unordered LIMIT can return the same arbitrary 200 each cycle, starving older rows).
    candidates = Stream
      .where(ended_at: nil)
      .where("started_at < ?", MIN_STREAM_AGE.ago)
      .order(started_at: :asc)
      .limit(BATCH_LIMIT)
      .pluck(:id, :channel_id, :started_at)

    enqueued = 0
    skipped = 0
    candidates.each do |stream_id, channel_id, started_at|
      latest_ccv_ts = CcvSnapshot.where(stream_id: stream_id).maximum(:timestamp)

      # Stale if no CCV at all (started > MIN_STREAM_AGE ago) OR last CCV older than cutoff.
      stale = latest_ccv_ts.nil? || latest_ccv_ts < cutoff
      unless stale
        skipped += 1
        next
      end

      enqueued += 1 if enqueue_offline(stream_id, channel_id, started_at, latest_ccv_ts)
    rescue StandardError => e
      Rails.logger.error("StaleStreamSweepWorker: failed to enqueue offline for stream_id=#{stream_id} (#{e.class}: #{e.message})")
    end

    Rails.logger.info("StaleStreamSweepWorker: scanned=#{candidates.size} enqueued=#{enqueued} skipped=#{skipped}")
  end

  private

  # CR-iter1 MF-1: delegate to StreamOfflineWorker so finalize_stream fills peak_ccv/avg_ccv/
  # duration_ms + triggers BotScoring/PostStream. Payload shape matches MonitoredLiveDetectorWorker
  # (broadcaster_user_id + broadcaster_user_login) — non-EventSub callers are supported.
  def enqueue_offline(stream_id, channel_id, started_at, last_ccv_ts)
    twitch_id, login = Channel.where(id: channel_id).pick(:twitch_id, :login)
    unless twitch_id && login
      Rails.logger.warn("StaleStreamSweepWorker: missing twitch_id/login for channel_id=#{channel_id} (stream_id=#{stream_id})")
      return false
    end

    StreamOfflineWorker.perform_async(
      { "broadcaster_user_id" => twitch_id, "broadcaster_user_login" => login },
      OFFLINE_SOURCE
    )
    Rails.logger.info(
      "StaleStreamSweepWorker: enqueued offline-close stream_id=#{stream_id} channel=#{login} " \
      "started_at=#{started_at.iso8601} last_ccv=#{last_ccv_ts&.iso8601 || 'none'}"
    )
    true
  end
end
