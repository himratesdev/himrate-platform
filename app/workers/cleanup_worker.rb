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
    deleted_ccv = cleanup_old_records(CcvSnapshot)
    deleted_chatters = cleanup_old_records(ChattersSnapshot)
    deleted_messages = cleanup_old_records(ChatMessage)

    Rails.logger.info(
      "CleanupWorker: deleted #{deleted_signals} signals, #{deleted_sessions} sessions, " \
      "#{deleted_ccv} ccv_snapshots, #{deleted_chatters} chatters_snapshots, #{deleted_messages} chat_messages"
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

  # TASK-033 FR-008: Generic timestamp-based cleanup.
  # Twitch max stream = 48h, so 90d cutoff is safe with no subqueries.
  def cleanup_old_records(model)
    cutoff = SIGNAL_TTL.ago
    total = 0

    loop do
      ids = model.where("timestamp < ?", cutoff)
                 .order(:timestamp)
                 .limit(BATCH_SIZE)
                 .pluck(:id)
      break if ids.empty?

      total += model.where(id: ids).delete_all
    end

    total
  end

  def cleanup_expired_sessions
    total = 0

    loop do
      deleted = Session.where(is_active: false).where(expires_at: ...Time.current)
                       .limit(BATCH_SIZE).delete_all
      total += deleted
      break if deleted < BATCH_SIZE
    end

    total
  end
end
