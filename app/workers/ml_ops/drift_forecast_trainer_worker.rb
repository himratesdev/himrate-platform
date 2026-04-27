# frozen_string_literal: true

# BUG-010 PR2 (PG fix B-1): Sidekiq wrapper around MlOps::DriftForecastTrainerService.
# Cron вызывает klass.new.perform — Service classes без include Sidekiq::Job не работают.
# Pattern matches CostAttribution::DailyAggregatorWorker.

module MlOps
  class DriftForecastTrainerWorker
    include Sidekiq::Job
    sidekiq_options queue: :long_running, retry: 2

    def perform
      MlOps::DriftForecastTrainerService.call
    end
  end
end
