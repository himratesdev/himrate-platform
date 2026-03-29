# frozen_string_literal: true

# TASK-023: Stub worker for EventSub channel.update events.
# Real implementation: TASK-030 (Signal Worker).

class ChannelUpdateWorker
  include Sidekiq::Job
  sidekiq_options queue: :default

  def perform(event_data)
    Rails.logger.info("ChannelUpdateWorker: #{event_data.to_json.truncate(200)}")
  end
end
