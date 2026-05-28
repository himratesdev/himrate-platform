# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-4 (FR-009 / M10): пересчёт weekly reflection одного юзера за одну неделю. Advisory-lock
  # per (user, week) (эталон SupporterStatusWorker, Trends::AggregationWorker — non-blocking,
  # auto-release на конец transaction). Триггер: WeeklyReflectionSchedulerWorker (weekly cron).
  # flag-gated :pva. week_start_iso = nil → последняя завершённая неделя (default из Builder).
  # Sidekiq strict_args требует JSON-native; неделя передаётся ISO-строкой, не Date.
  class WeeklyReflectionWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    def perform(user_id, week_start_iso = nil)
      return unless Flipper.enabled?(:pva)

      week_start = parse_week_start(week_start_iso)
      ActiveRecord::Base.transaction do
        unless try_advisory_lock(hashtext_lock_key("pva_reflection:#{user_id}:#{week_start}"))
          self.class.perform_in(30.seconds, user_id, week_start_iso)
          next
        end

        PersonalAnalytics::Reflection::ReflectionBuilder.call(user_id, week_start: week_start)
      end
    end

    private

    def parse_week_start(iso)
      return nil if iso.blank?

      Date.iso8601(iso.to_s)
    rescue ArgumentError
      nil
    end

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
