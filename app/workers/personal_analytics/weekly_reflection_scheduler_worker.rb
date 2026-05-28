# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-4 (FR-009 / M10): weekly cron — fan-out пересчёта reflection по юзерам с view-rollup'ами.
  # Эталон SupporterStatusSchedulerWorker / Trends::NightlyAggregationWorker (throttled fan-out,
  # queue :monitoring). flag-gated :pva. Reflection = retention-движок (PO-критичная неделя).
  class WeeklyReflectionSchedulerWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    THROTTLE_EVERY = 500
    THROTTLE_SECONDS = 0.05

    def perform
      return unless Flipper.enabled?(:pva)

      enqueued = 0
      candidate_user_ids.each do |user_id|
        PersonalAnalytics::WeeklyReflectionWorker.perform_async(user_id)
        enqueued += 1
        sleep(THROTTLE_SECONDS) if (enqueued % THROTTLE_EVERY).zero?
      end
      enqueued
    end

    private

    # Кандидаты = юзеры с view-rollup'ами (reflection = нарратив из viewing-агрегатов).
    def candidate_user_ids
      PvaViewRollup.distinct.pluck(:user_id)
    end
  end
end
