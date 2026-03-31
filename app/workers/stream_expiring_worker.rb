# frozen_string_literal: true

# TASK-033 FR-009: Broadcast stream_expiring 1h before 18h window closes.
# Scheduled by PostStreamWorker at stream.ended_at + 17h.

class StreamExpiringWorker
  include Sidekiq::Job
  sidekiq_options queue: :notifications, retry: 1

  def perform(stream_id)
    stream = Stream.find_by(id: stream_id)
    unless stream
      Rails.logger.warn("StreamExpiringWorker: stream #{stream_id} not found")
      return
    end

    channel = stream.channel

    # Skip if new stream is live (old window already closed)
    if channel.live?
      Rails.logger.info("StreamExpiringWorker: channel #{channel.login} is live, skipping expiring warning")
      return
    end

    # Skip if window already expired
    if stream.ended_at && Time.current > stream.ended_at + 18.hours
      Rails.logger.info("StreamExpiringWorker: window already expired for stream #{stream_id}")
      return
    end

    PostStreamNotificationService.broadcast_stream_expiring(stream)

    Rails.logger.info("StreamExpiringWorker: stream_expiring broadcast for #{channel.login} stream #{stream_id}")
  end
end
