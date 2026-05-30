# frozen_string_literal: true

# TASK-251.58: Sidekiq cron-driven backfill cycle for Clickhouse::ChatBackfill (and any future
# backfill that follows the same Redis-cursor pattern). Replaces the prior `detached rake +
# setsid wrapper` operator pattern that died on every Kamal deploy (container swap), requiring
# manual re-spawn — observed 4× kills during TASK-251.14 chat backfill window 2026-05-29.
#
# Pattern (same as `chat_message_drain` per config/initializers/sidekiq_cron.rb): cron fires every
# minute → worker runs Clickhouse::ChatBackfill#tick in a loop until MAX_RUNTIME_SECONDS (50s,
# < 60s cadence → no overlapping runs) → exits → cron re-runs next minute. Sidekiq cron registers
# on each Sidekiq boot, so the cycle resumes natively after `kamal deploy` (no operator action).
#
# Kill-switch: `:chat_backfill_running` (existing). T0 (watermark) must be set in Redis BEFORE
# the cycle can start — operator sets via `rake clickhouse:set_backfill_t0[T0_ISO]` (or by
# invoking the existing `rake clickhouse:backfill_chat[...]` once, which sets T0 then runs the
# blocking loop). After T0 is in Redis, the worker uses it automatically.
module Clickhouse
  class ChatBackfillCycleWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    MAX_RUNTIME_SECONDS = 50
    INTER_BATCH_SLEEP_SECONDS = 0.5

    def perform
      return unless Flipper.enabled?(:chat_backfill_running)

      t0_iso = redis.get("#{Clickhouse::ChatBackfill::REDIS_PREFIX}:t0")
      if t0_iso.blank?
        Rails.logger.warn("ChatBackfillCycleWorker: T0 not set in Redis (#{Clickhouse::ChatBackfill::REDIS_PREFIX}:t0) — operator must seed via `rake clickhouse:set_backfill_t0[T0_ISO]` or `rake clickhouse:backfill_chat[T0_ISO]` first. Skipping cycle.")
        return
      end

      t0 = Time.iso8601(t0_iso)
      backfill = Clickhouse::ChatBackfill.new(t0: t0)
      deadline = Time.current + MAX_RUNTIME_SECONDS
      ticks = 0

      loop do
        break if Time.current >= deadline

        result = backfill.tick

        case result[:status]
        when :ok
          ticks += 1
          sleep(INTER_BATCH_SLEEP_SECONDS)
        when :done
          Rails.logger.info("ChatBackfillCycleWorker: status=done — no more pre-T0 rows; rows_processed=#{result[:rows_processed]}, ticks=#{ticks}. Cron stays scheduled but next run will short-circuit (status=done in Redis).")
          return
        when :paused
          Rails.logger.info("ChatBackfillCycleWorker: kill-switch OFF (:chat_backfill_running) — paused at cursor=#{result[:cursor]}, rows_processed=#{result[:rows_processed]}, ticks=#{ticks}")
          return
        when :failed
          Rails.logger.error("ChatBackfillCycleWorker: tick failed at cursor=#{result[:cursor]} batch_size=#{result[:batch_size]} err=#{result[:last_error]} ticks=#{ticks}. Redis status='failed'; operator must inspect Redis `#{Clickhouse::ChatBackfill::REDIS_PREFIX}:last_error` and clear status before next cron fire will retry.")
          return
        end
      end

      Rails.logger.info("ChatBackfillCycleWorker: ran #{ticks} ticks within #{MAX_RUNTIME_SECONDS}s budget — cron will re-fire next minute")
    rescue ArgumentError => e
      Rails.logger.error("ChatBackfillCycleWorker: T0 parse failed (#{e.message}) — Redis value invalid; operator must reset")
    end

    private

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
