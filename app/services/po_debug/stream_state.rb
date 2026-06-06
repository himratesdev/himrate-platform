# frozen_string_literal: true

module PoDebug
  # Block 1 — current stream state for the PO's Twitch channel.
  #
  # Source: Channel.find_by(login: ENV['PO_TWITCH_LOGIN']) → Stream.active.last.
  # Derived peak_ccv / avg_ccv via PR-A1 (#current_peak_ccv on Stream).
  class StreamState
    def self.call
      new.call
    end

    def call
      channel = po_channel
      return { state: "no_channel", po_login: po_login } unless channel

      stream = channel.streams.active.order(started_at: :desc).first
      if stream
        live_payload(channel, stream)
      else
        offline_payload(channel)
      end
    end

    private

    def po_login
      ENV.fetch("PO_TWITCH_LOGIN", "himych")
    end

    def po_channel
      Channel.find_by(login: po_login)
    end

    def live_payload(channel, stream)
      latest_snapshot = stream.ccv_snapshots.order(timestamp: :desc).first
      latest_ts = latest_snapshot&.timestamp
      {
        state: "live",
        channel: {
          login: channel.login,
          display_name: channel.display_name,
          twitch_id: channel.twitch_id,
          broadcaster_type: channel.broadcaster_type,
          followers_total: channel.followers_total
        },
        stream: {
          id: stream.id,
          started_at: stream.started_at&.iso8601,
          duration_min: stream.started_at ? ((Time.current - stream.started_at) / 60.0).round(1) : nil,
          peak_ccv: stream.current_peak_ccv,
          avg_ccv: stream.current_avg_ccv,
          latest_viewer_count: latest_snapshot&.ccv_count,
          latest_snapshot_at: latest_ts&.iso8601,
          ccv_snapshot_count: stream.ccv_snapshots.count
        }
      }
    end

    def offline_payload(channel)
      last_stream = channel.streams.where.not(ended_at: nil).order(ended_at: :desc).first
      {
        state: "offline",
        channel: {
          login: channel.login,
          display_name: channel.display_name,
          twitch_id: channel.twitch_id
        },
        last_stream: last_stream && {
          id: last_stream.id,
          started_at: last_stream.started_at&.iso8601,
          ended_at: last_stream.ended_at&.iso8601,
          peak_ccv: last_stream.current_peak_ccv,
          minutes_since_end: ((Time.current - last_stream.ended_at) / 60.0).round(1)
        }
      }
    end
  end
end
