# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-4 (FR-010 / M11): пересчёт rule-based patterns одного юзера. Advisory-lock per user
  # (эталон SupporterStatusWorker / WeeklyReflectionWorker). flag-gated :pva.
  class PatternsWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    def perform(user_id)
      return unless Flipper.enabled?(:pva)

      ActiveRecord::Base.transaction do
        unless try_advisory_lock(hashtext_lock_key("pva_patterns:#{user_id}"))
          self.class.perform_in(30.seconds, user_id)
          next
        end

        PersonalAnalytics::Patterns::PatternsBuilder.call(user_id)
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
