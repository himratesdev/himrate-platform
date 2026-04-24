# frozen_string_literal: true

# TASK-039 FR-018 + FR-038: Daily aggregation worker для trends_daily_aggregates.
#
# Triggered:
#   - PostStreamWorker при каждом stream end (aggregates stream's date)
#   - Nightly cron (batch re-aggregation — Phase B3 / E)
#   - Backfill rake (Phase E)
#
# Concurrency safety (ADR §4.3): pg_try_advisory_xact_lock(hashtext(key)::bigint)
#   - Zero new dependency (vs sidekiq-unique-jobs gem)
#   - xact_lock auto-released на конец transaction (не нужен explicit unlock)
#   - try_ = non-blocking (если lock held → logs skip + returns, no blocking wait)
#   - hashtext(...) PG builtin fast hash
#
# Namespace prefix "trends_aggregation:" — scoped lock key для избежания collision
# с другими advisory locks в системе (future workers).
#
# Safe SQL: hashtext через sanitize_sql_array (parameterized), lock result
# cast .to_i перед interpolation — Brakeman-verified safe pattern.

module Trends
  class AggregationWorker
    include Sidekiq::Job
    sidekiq_options queue: :signals, retry: 3

    def perform(channel_id, date)
      # PG-iter1 cosmetic: start_monotonic первой строкой — гарантирует что
      # ensure-block duration_ms всегда defined (consistent с
      # AnomalyAttributionWorker, защищает от theoretical hashtext failure
      # masking original error через nil arithmetic в ensure).
      start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      date_str = date.to_s
      lock_key = hashtext_lock_key("trends_aggregation:#{channel_id}:#{date_str}")

      # SRS §10: emit duration + failure events для trends_aggregation_worker.*
      # alerts. Subscribers (StatsD/Prometheus/Sentry) attach за кадром.
      lock_contested = false

      ActiveRecord::Base.transaction do
        unless try_advisory_lock(lock_key)
          # CR N-1: re-enqueue с delay вместо silent skip. Scenario: Worker1
          # читает TIH snapshot → работает → Worker2 tries lock (busy) → skip.
          # Если Stream B's TIH committed между Worker1's read и commit, Worker1
          # её не увидит. Re-enqueue через 30s гарантирует re-aggregation
          # с fresh snapshot (Worker1 к тому моменту complete, lock released).
          # Sidekiq retry (3 attempts) handles если worker still running после 30s.
          self.class.perform_in(30.seconds, channel_id, date_str)
          Rails.logger.info(
            "Trends::AggregationWorker: lock busy для channel=#{channel_id} date=#{date_str} " \
            "— re-enqueued с 30s delay"
          )
          lock_contested = true
          return
        end

        Trends::Aggregation::DailyBuilder.call(channel_id, date_str)

        Rails.logger.info(
          "Trends::AggregationWorker: aggregated channel=#{channel_id} date=#{date_str}"
        )
      end
    rescue StandardError => e
      ActiveSupport::Notifications.instrument(
        "trends.aggregation_worker.failed",
        channel_id: channel_id,
        date: date_str,
        error_class: e.class.name
      )
      raise
    ensure
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round(2)
      ActiveSupport::Notifications.instrument(
        "trends.aggregation_worker.completed",
        channel_id: channel_id,
        date: date_str,
        duration_ms: duration_ms,
        lock_contested: lock_contested
      )
    end

    private

    # hashtext PG builtin через parameterized query (Brakeman-safe).
    # Returns bigint coerced .to_i для downstream interpolation safety.
    def hashtext_lock_key(key)
      result = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT hashtext(?)::bigint", key ])
      )
      result.to_i
    end

    # try_advisory_xact_lock с Integer lock_key (already sanitized в hashtext_lock_key).
    # Parameterized query — Brakeman-safe.
    def try_advisory_lock(lock_key)
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(?)", lock_key.to_i ])
      )
    end
  end
end
