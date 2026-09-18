# frozen_string_literal: true

module Twitch
  # WS2: resolves a Hermes `video-playback-by-id` viewcount push to the currently-live Stream and
  # persists a realtime CcvSnapshot, including Twitch's undocumented costream split
  # (collaboration_viewers/collaboration_status). Extracted from bin/hermes_monitor so the
  # resolve-and-persist logic — the whole point of the collaboration_viewers migration — is unit
  # testable rather than living inside the entrypoint's callback.
  class HermesSnapshotWriter
    def initialize
      @stream_cache = {}
    end

    # Drop the channel_id -> Stream cache so a new active cycle picks up newly-live / ended streams.
    def reset_cache
      @stream_cache = {}
    end

    # Returns the created CcvSnapshot, or nil when the push has no count / no live stream.
    def write(channel_id, payload)
      viewers = payload["viewers"]
      # A viewcount push missing the count would write a spurious ccv_count:0 and poison the CCV
      # series (the empty-source false-zero failure class). The poll path guards `if ccv`; match it.
      return if viewers.nil?

      stream = live_stream_for(channel_id)
      return unless stream

      CcvSnapshot.create!(
        stream: stream,
        timestamp: Time.current,
        ccv_count: viewers.to_i,
        collaboration_viewers: payload["collaboration_viewers"],
        collaboration_status: payload["collaboration_status"]
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      Rails.logger.warn("HermesSnapshotWriter: write failed for #{channel_id} (#{e.message})")
      nil
    end

    private

    def live_stream_for(channel_id)
      return @stream_cache[channel_id] if @stream_cache.key?(channel_id)

      channel = Channel.find_by(twitch_id: channel_id.to_s)
      @stream_cache[channel_id] =
        channel&.streams&.where(ended_at: nil)&.order(started_at: :desc)&.first
    end
  end
end
