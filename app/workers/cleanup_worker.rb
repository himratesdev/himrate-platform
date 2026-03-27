# frozen_string_literal: true

# TASK-016: Skeleton cleanup worker for expired data.
# Runs on monitoring queue (lowest priority).
# Real scheduling (cron) in TASK-025.

class CleanupWorker
  include Sidekiq::Job

  sidekiq_options queue: :monitoring, retry: 3

  SIGNAL_TTL = 90.days
  BATCH_SIZE = 1_000

  def perform
    deleted_signals = cleanup_old_signals
    deleted_sessions = cleanup_expired_sessions

    Rails.logger.info(
      "CleanupWorker: deleted #{deleted_signals} signals, #{deleted_sessions} sessions"
    )
  end

  private

  def cleanup_old_signals
    cutoff = SIGNAL_TTL.ago
    total = 0

    loop do
      deleted = TiSignal.where(timestamp: ...cutoff).limit(BATCH_SIZE).delete_all
      total += deleted
      break if deleted < BATCH_SIZE
    end

    total
  end

  def cleanup_expired_sessions
    Session.where(is_active: false).where(expires_at: ...Time.current).delete_all
  end
end
