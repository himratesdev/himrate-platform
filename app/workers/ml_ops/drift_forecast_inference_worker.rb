# frozen_string_literal: true

# BUG-010 PR2 (PG fix B-1): Sidekiq wrapper around MlOps::DriftForecastInferenceService.
# Same pattern as DriftForecastTrainerWorker.

module MlOps
  class DriftForecastInferenceWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 2

    def perform
      MlOps::DriftForecastInferenceService.call
    end
  end
end
