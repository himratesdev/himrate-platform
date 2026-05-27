# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-2: per-user viewing aggregation. ETL SyncEvent stream_view → pva_view_events,
  # затем rebuild затронутых daily-бакетов pva_view_rollups. Триггерится после SyncEventBatchWorker
  # (sync push, flag-gated :pva). Advisory lock per user (зеркало Trends::AggregationWorker, ADR §4.3:
  # pg_try_advisory_xact_lock(hashtext(key)) — non-blocking, auto-release на конец transaction).
  class ViewAggregationWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    def perform(user_id)
      return unless Flipper.enabled?(:pva)

      start_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      lock_contested = false

      begin
        lock_contested = aggregate(user_id)
      rescue StandardError => e
        ActiveSupport::Notifications.instrument(
          "personal_analytics.view_aggregation_worker.failed", user_id: user_id, error_class: e.class.name
        )
        raise
      ensure
        duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_monotonic) * 1000).round(2)
        ActiveSupport::Notifications.instrument(
          "personal_analytics.view_aggregation_worker.completed",
          user_id: user_id, duration_ms: duration_ms, lock_contested: lock_contested
        )
      end
    end

    private

    # Returns true если lock contested (re-enqueued), иначе false.
    def aggregate(user_id)
      ActiveRecord::Base.transaction do
        unless try_advisory_lock(hashtext_lock_key("pva_view_aggregation:#{user_id}"))
          self.class.perform_in(30.seconds, user_id)
          next true
        end

        affected_dates = PersonalAnalytics::Aggregation::ViewEventEtl.call(user_id)
        affected_dates.each { |date| PersonalAnalytics::Aggregation::ViewRollupBuilder.call(user_id, date) }
        false
      end
    end

    # hashtext PG builtin через parameterized query (Brakeman-safe), .to_i для downstream interpolation.
    def hashtext_lock_key(key)
      result = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT hashtext(?)::bigint", key ])
      )
      result.to_i
    end

    def try_advisory_lock(lock_key)
      ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(?)", lock_key.to_i ])
      )
    end
  end
end
