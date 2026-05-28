# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-4 (FR-011 / M12): weekly cron — fan-out пересчёта когорты по юзерам с Twitch OAuth
  # (cohort требует twitch login → username в cross_channel_presences). Эталон SupporterStatusScheduler.
  # flag-gated :pva.
  class CohortSchedulerWorker
    include Sidekiq::Job
    sidekiq_options queue: :monitoring, retry: 1

    THROTTLE_EVERY = 500
    THROTTLE_SECONDS = 0.05

    def perform
      return unless Flipper.enabled?(:pva)

      enqueued = 0
      candidate_user_ids.each do |user_id|
        PersonalAnalytics::CohortWorker.perform_async(user_id)
        enqueued += 1
        sleep(THROTTLE_SECONDS) if (enqueued % THROTTLE_EVERY).zero?
      end
      enqueued
    end

    private

    # Кандидаты = юзеры с активным Twitch OAuth provider (без него нет twitch_login → cohort no-op).
    def candidate_user_ids
      AuthProvider.where(provider: "twitch").distinct.pluck(:user_id)
    end
  end
end
