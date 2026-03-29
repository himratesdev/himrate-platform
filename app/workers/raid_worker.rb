# frozen_string_literal: true

# TASK-023: Stub worker for EventSub channel.raid events.
# Real implementation: TASK-028 (Signal #9 Raid Attribution).

class RaidWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  def perform(event_data)
    Rails.logger.info("RaidWorker: #{event_data.to_json.truncate(200)}")
  end
end
