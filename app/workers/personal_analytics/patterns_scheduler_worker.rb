# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-4 (FR-010 / M11): weekly cron — fan-out пересчёта patterns по юзерам с view-rollup'ами.
  # Эталон SupporterStatusSchedulerWorker / Trends::NightlyAggregationWorker. flag-gated :pva.
  class PatternsSchedulerWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    THROTTLE_EVERY = 500
    THROTTLE_SECONDS = 0.05

    def perform
      return unless Flipper.enabled?(:pva)

      enqueued = 0
      candidate_user_ids.each do |user_id|
        PersonalAnalytics::PatternsWorker.perform_async(user_id)
        enqueued += 1
        sleep(THROTTLE_SECONDS) if (enqueued % THROTTLE_EVERY).zero?
      end
      enqueued
    end

    private

    # Кандидаты = юзеры с rollup'ами в последних 60 днях (нужно для trend last-vs-prev).
    def candidate_user_ids
      PvaViewRollup.where(date: 60.days.ago.to_date..Date.current)
                   .distinct.pluck(:user_id)
    end
  end
end
