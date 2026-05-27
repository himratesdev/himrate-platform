# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3 (M9): пересчёт supporter-статуса одного юзера. Advisory-lock per user (эталон
  # Trends::AggregationWorker, ADR §4.3 — non-blocking, auto-release на конец transaction). Триггер:
  # SupporterStatusSchedulerWorker (weekly cron). flag-gated :pva.
  class SupporterStatusWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    def perform(user_id)
      return unless Flipper.enabled?(:pva)

      ActiveRecord::Base.transaction do
        unless try_advisory_lock(hashtext_lock_key("pva_supporter:#{user_id}"))
          self.class.perform_in(30.seconds, user_id)
          next
        end

        PersonalAnalytics::Supporter::StatusBuilder.call(user_id)
      end
    end

    private

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
