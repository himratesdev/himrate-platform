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
      date_str = date.to_s
      lock_key = hashtext_lock_key("trends_aggregation:#{channel_id}:#{date_str}")

      ActiveRecord::Base.transaction do
        unless try_advisory_lock(lock_key)
          Rails.logger.info(
            "Trends::AggregationWorker: skipped channel=#{channel_id} date=#{date_str} " \
            "(lock held by another worker)"
          )
          return
        end

        Trends::Aggregation::DailyBuilder.call(channel_id, date_str)

        Rails.logger.info(
          "Trends::AggregationWorker: aggregated channel=#{channel_id} date=#{date_str}"
        )
      end
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
