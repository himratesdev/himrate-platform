# frozen_string_literal: true

# TASK-023: Stub worker for EventSub channel.follow events.
# Real implementation: TASK-030 (follower spike detection).

class FollowWorker
  include Sidekiq::Job
  sidekiq_options queue: :default

  def perform(event_data)
    Rails.logger.info("FollowWorker: #{event_data.to_json.truncate(200)}")
  end
end
