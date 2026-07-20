# frozen_string_literal: true

module Moments
  # Screen 07: fetches the Twitch clips created inside one FINISHED stream's window and caches them
  # for the moments endpoint. Helix runs Sidekiq-side only (HelixClient retry sleep() blocks a Puma
  # thread — repo convention); the endpoint serves from this cache and returns clips_status=pending
  # on a cold miss. A finished stream's clip set is near-immutable → 24h cache; PENDING marker
  # prevents an enqueue storm while a fetch is in flight.
  class ClipsFetchWorker
    include Sidekiq::Worker
    sidekiq_options queue: :default, retry: 2

    CACHE_TTL = 24.hours
    PENDING_TTL = 2.minutes
    CLIP_LIMIT = 50

    def self.cache_key(stream_id) = "moments:clips:v1:#{stream_id}"
    def self.pending_key(stream_id) = "moments:clips:v1:#{stream_id}:pending"

    def perform(stream_id)
      stream = Stream.find_by(id: stream_id)
      return if stream.nil? || stream.ended_at.nil?

      clips = Twitch::HelixClient.new.get_clips(
        broadcaster_id: stream.channel.twitch_id,
        first: CLIP_LIMIT,
        started_at: stream.started_at,
        ended_at: stream.ended_at
      ) || []

      payload = clips.map do |c|
        {
          "id" => c["id"],
          "title" => c["title"],
          "url" => c["url"],
          "view_count" => c["view_count"].to_i,
          "duration" => c["duration"]&.to_f,
          "thumbnail_url" => c["thumbnail_url"],
          "vod_offset" => c["vod_offset"], # seconds into the VOD — matches moments by window (DSV)
          "created_at" => c["created_at"]
        }
      end

      Rails.cache.write(self.class.cache_key(stream_id), payload, expires_in: CACHE_TTL)
    ensure
      Rails.cache.delete(self.class.pending_key(stream_id))
    end
  end
end
