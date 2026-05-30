# frozen_string_literal: true

# TASK-251.58: Sidekiq cron-driven backfill cycle for Clickhouse::ChatBackfill (and any future
# backfill that follows the same Redis-cursor pattern). Replaces the prior `detached rake +
# setsid wrapper` operator pattern that died on every Kamal deploy (container swap), requiring
# manual re-spawn — observed 4× kills during TASK-251.14 chat backfill window 2026-05-29.
#
# Pattern (same as `chat_message_drain` per config/initializers/sidekiq_cron.rb): cron fires every
# minute → worker runs Clickhouse::ChatBackfill#tick in a loop until MAX_RUNTIME_SECONDS (50s,
# < 60s cadence) → exits → cron re-fires next minute. Sidekiq cron registers on each Sidekiq boot,
# so the cycle resumes natively after `kamal deploy` (no operator action).
#
# CR iter1 M1 — overlap prevention: sidekiq-cron only ENQUEUES at the cadence, it does NOT lock
# against a still-running prior job. Two concurrent ticks would read the same Redis cursor, fetch
# the same PG batch, and insert duplicate rows into the raw chat_messages CH table (MergeTree,
# NO engine-level dedup — explicitly called out in `chat_backfill.rb` T0 safety-margin comment).
# We take a cross-process SETNX lock with TTL > MAX_RUNTIME_SECONDS as the actual overlap guard.
#
# Kill-switch: `:chat_backfill_running` (existing). T0 (watermark) must be set in Redis BEFORE
# the cycle can start — operator seeds T0 via `rake clickhouse:backfill_chat[T0_ISO]` (the rake
# task sets T0 in Redis and exits; the cron worker picks up T0 on its next tick, ≤60s).
module Clickhouse
  class ChatBackfillCycleWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 1

    # Must stay strictly < 60s cron cadence (see sidekiq_cron.rb `chat_backfill_cycle`) so the
    # next cron tick fires only after the current run's lock has expired in the worst case.
    MAX_RUNTIME_SECONDS = 50
    INTER_BATCH_SLEEP_SECONDS = 0.5

    # CR iter1 M1 + CR iter3 Should-1: cross-process overlap lock — shared with
    # Clickhouse::ChatBackfill#call (rake operator path) via Clickhouse::BackfillCycleLock so
    # both entry points cannot interleave concurrent #tick calls (which would double-insert into
    # the no-engine-dedup CH MergeTree). Lock helpers extracted to a module so both call sites
    # use the same KEY / TTL / raw-call-form (CR iter2 M1).
    LOCK_TTL_SECONDS = Clickhouse::BackfillCycleLock::DEFAULT_TTL_SECONDS

    def perform
      return unless Flipper.enabled?(:chat_backfill_running)

      # CR iter1 S1: short-circuit once backfill terminally finished, so the cron entry stays
      # scheduled (for future re-backfills) but does not spam the log with "status=done" every
      # minute forever. Operator clears the key (`DEL clickhouse:backfill:chat:status`) to re-arm
      # the cycle — symmetric to flipping the `:chat_backfill_running` kill-switch back ON.
      return if redis_get("#{Clickhouse::ChatBackfill::REDIS_PREFIX}:status") == "done"

      t0_iso = redis_get("#{Clickhouse::ChatBackfill::REDIS_PREFIX}:t0")
      if t0_iso.blank?
        Rails.logger.warn("ChatBackfillCycleWorker: T0 not set in Redis (#{Clickhouse::ChatBackfill::REDIS_PREFIX}:t0) — operator must seed via `rake clickhouse:backfill_chat[T0_ISO]` (which sets T0 as a side-effect before entering its loop). Skipping cycle.")
        return
      end

      # CR iter2 S2: parse T0 BEFORE acquiring the lock and with a narrow rescue. The original
      # outer `rescue ArgumentError` caught any ArgumentError from inside the inner loop (e.g.
      # AR validation, Rails internals) and mislabeled it as "T0 parse failed". A scoped rescue
      # here makes the failure mode unambiguous + avoids burning a lock acquire on bad config.
      t0 = begin
        Time.iso8601(t0_iso)
      rescue ArgumentError => e
        Rails.logger.error("ChatBackfillCycleWorker: T0 parse failed (#{e.message}) — Redis value invalid (#{t0_iso.inspect}); operator must reset `#{Clickhouse::ChatBackfill::REDIS_PREFIX}:t0`")
        return
      end

      lock_token = SecureRandom.hex(16)
      acquired = Sidekiq.redis { |c| Clickhouse::BackfillCycleLock.acquire(c, lock_token) }
      unless acquired
        Rails.logger.info("ChatBackfillCycleWorker: cycle lock already held (cron tick OR rake operator path) — skipping (cron will re-fire next minute)")
        return
      end

      begin
        backfill = Clickhouse::ChatBackfill.new(t0: t0)
        deadline = clock.call + MAX_RUNTIME_SECONDS
        ticks = 0

        loop do
          break if clock.call >= deadline

          result = backfill.tick

          case result[:status]
          when :ok
            ticks += 1
            sleep(INTER_BATCH_SLEEP_SECONDS)
          when :done
            Rails.logger.info("ChatBackfillCycleWorker: status=done — no more pre-T0 rows; rows_processed=#{result[:rows_processed]}, ticks=#{ticks}. Cron will short-circuit until operator clears `#{Clickhouse::ChatBackfill::REDIS_PREFIX}:status`.")
            return
          when :paused
            Rails.logger.info("ChatBackfillCycleWorker: kill-switch OFF (:chat_backfill_running) — paused at cursor=#{result[:cursor]}, rows_processed=#{result[:rows_processed]}, ticks=#{ticks}")
            return
          when :failed
            # CR iter2 S1: auto-retry IS the actual behavior — Redis cursor was not advanced
            # (see Clickhouse::ChatBackfill#tick failure path), so the next cron tick will re-attempt
            # the same batch. Correct + desired for transient CH errors. The prior log line claimed
            # "operator must clear status before retry" which contradicted the code.
            Rails.logger.error("ChatBackfillCycleWorker: tick failed at cursor=#{result[:cursor]} batch_size=#{result[:batch_size]} err=#{result[:last_error]} ticks=#{ticks}. Cursor not advanced — next cron tick will auto-retry the same batch. Inspect `#{Clickhouse::ChatBackfill::REDIS_PREFIX}:last_error` for persistent failures.")
            return
          end
        end

        Rails.logger.info("ChatBackfillCycleWorker: ran #{ticks} ticks within #{MAX_RUNTIME_SECONDS}s budget — cron will re-fire next minute")
      ensure
        Sidekiq.redis { |c| Clickhouse::BackfillCycleLock.release(c, lock_token) }
      end
    end

    # CR iter1 N3: clock injection. The default is `-> { Time.current }`, but specs can swap in a
    # deterministic clock without stubbing global Time methods (which is fragile because Rails
    # instrumentation, logging, etc. all call `Time.current` and exhaust the stub queue).
    def clock
      @clock ||= -> { Time.current }
    end
    attr_writer :clock

    private

    # CR iter1 S2: use the existing Sidekiq Redis pool instead of opening a fresh TCP connection
    # per `#perform` invocation. Consistent with the rest of the worker fleet.
    def redis_get(key)
      Sidekiq.redis { |c| c.get(key) }
    end

    # Lock acquire/release now delegated to Clickhouse::BackfillCycleLock module (shared with
    # the rake operator path via Clickhouse::ChatBackfill#call). See CR iter3 Should-1 + iter2 M1.
  end
end
