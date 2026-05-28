# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3 (M9): weekly cron — fan-out пересчёта supporter-статуса по юзерам с engagement/tenure
  # данными. Эталон Trends::NightlyAggregationWorker (throttled fan-out, queue :monitoring). flag-gated :pva.
  class SupporterStatusSchedulerWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    THROTTLE_EVERY = 500
    THROTTLE_SECONDS = 0.05

    def perform
      return unless Flipper.enabled?(:pva)

      enqueued = 0
      candidate_user_ids.each do |user_id|
        PersonalAnalytics::SupporterStatusWorker.perform_async(user_id)
        enqueued += 1
        sleep(THROTTLE_SECONDS) if (enqueued % THROTTLE_EVERY).zero?
      end
      enqueued
    end

    private

    def candidate_user_ids
      (PvaEngagementEvent.distinct.pluck(:user_id) + ChannelTenure.distinct.pluck(:user_id)).uniq
    end
  end
end
