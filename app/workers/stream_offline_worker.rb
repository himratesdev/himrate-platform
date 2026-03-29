# frozen_string_literal: true

# TASK-023: Stub worker for EventSub stream.offline events.
# Real implementation: TASK-025, TASK-033 (Post-Stream).

class StreamOfflineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  def perform(event_data)
    Rails.logger.info("StreamOfflineWorker: #{event_data.to_json.truncate(200)}")
  end
end
