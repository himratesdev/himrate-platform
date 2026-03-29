# frozen_string_literal: true

# TASK-023: Stub worker for EventSub stream.online events.
# Real implementation: TASK-025 (Stream Monitor).

class StreamOnlineWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  def perform(event_data)
    Rails.logger.info("StreamOnlineWorker: #{event_data.to_json.truncate(200)}")
  end
end
