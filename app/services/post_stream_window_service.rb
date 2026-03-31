# frozen_string_literal: true

# TASK-032 FR-006: Post-stream window service.
# Determines if FREE user can see drill-down data for a channel.
# Window: 18 hours after stream ends OR until next stream starts (whichever first).
# Used by: ChannelPolicy, TrustController, StreamsController, ErvController.

class PostStreamWindowService
  # Returns true if post-stream drill-down window is open for this channel.
  # A new live stream immediately closes the previous window.
  def self.open?(channel)
    last_ended_stream = channel.streams
                               .where.not(ended_at: nil)
                               .order(ended_at: :desc)
                               .first

    return false unless last_ended_stream

    # If channel has a live stream, old window is closed (new live = new data)
    has_live = channel.streams.where(ended_at: nil).exists?
    return false if has_live && last_ended_stream.ended_at < Time.current

    # Window: 18 hours from stream end
    expires_at = last_ended_stream.ended_at + 18.hours

    # Check no newer stream started after this one ended
    newer_stream_started = channel.streams
                                  .where("started_at > ?", last_ended_stream.ended_at)
                                  .exists?

    return false if newer_stream_started

    Time.current < expires_at
  end

  # Returns the expiration time of the current window (nil if closed).
  def self.expires_at(channel)
    last_ended_stream = channel.streams
                               .where.not(ended_at: nil)
                               .order(ended_at: :desc)
                               .first

    return nil unless last_ended_stream

    newer_stream_started = channel.streams
                                  .where("started_at > ?", last_ended_stream.ended_at)
                                  .exists?

    return nil if newer_stream_started

    candidate = last_ended_stream.ended_at + 18.hours
    candidate > Time.current ? candidate : nil
  end

  # Returns the last ended stream (for report access).
  def self.last_ended_stream(channel)
    channel.streams
           .where.not(ended_at: nil)
           .order(ended_at: :desc)
           .first
  end
end
