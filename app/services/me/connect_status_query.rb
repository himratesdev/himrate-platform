# frozen_string_literal: true

module Me
  # ONBOARD-D0 (screen 11): REAL data-source status for the user's own twitch channel.
  # No mod-bot / autoposting exist — the surface reports what actually runs: observation
  # (TrackedChannel + is_monitored), OAuth link + granted scopes, and collection stats
  # (streams, hours live, active sources in the last 15 minutes, freshest sync).
  class ConnectStatusQuery
    def initialize(user)
      @user = user
    end

    def call
      twitch = @user.auth_providers.find { |p| p.provider == "twitch" }
      return { oauth: { linked: false }, observation: nil, stats: nil } unless twitch

      channel = Channel.find_by(twitch_id: twitch.provider_id)
      {
        oauth: { linked: true, login: @user.username, scopes: Array(twitch.scopes) },
        observation: observation(channel),
        stats: channel ? stats(channel) : empty_stats
      }
    end

    private

    def observation(channel)
      return { channel_id: nil, tracked: false, is_monitored: false, since: nil } unless channel

      tracked = TrackedChannel.find_by(user: @user, channel: channel, tracking_enabled: true)
      { channel_id: channel.id, tracked: tracked.present?, is_monitored: channel.is_monitored,
        since: tracked&.added_at&.iso8601 }
    end

    def stats(channel)
      streams = Stream.where(channel_id: channel.id).where.not(ended_at: nil)
      hours = PostStreamReport.joins(:stream).where(streams: { channel_id: channel.id })
                              .sum(:duration_ms) / 3_600_000.0
      last_tih = TrustIndexHistory.where(channel_id: channel.id).maximum(:calculated_at)
      last_ccv = CcvSnapshot.joins(:stream).where(streams: { channel_id: channel.id })
                            .maximum(:timestamp)
      {
        streams_collected: streams.count,
        hours_live: hours.round(1),
        sources_active: active_sources(channel, last_ccv),
        last_sync_at: [ last_tih, last_ccv ].compact.max&.iso8601
      }
    end

    def empty_stats
      { streams_collected: 0, hours_live: 0.0, sources_active: 0, last_sync_at: nil }
    end

    # Sources genuinely emitting in the last 15 minutes: chat (CH), ccv snapshots, helix/TIH.
    def active_sources(channel, last_ccv)
      n = 0
      n += 1 if chat_active?(channel.login)
      n += 1 if last_ccv && last_ccv > 15.minutes.ago
      n += 1 if TrustIndexHistory.where(channel_id: channel.id)
                                 .where("calculated_at > ?", 15.minutes.ago).exists?
      n
    end

    def chat_active?(login)
      rows = Clickhouse::Client.new.select(
        "SELECT count() AS c FROM chat_messages WHERE channel_login = '#{login.gsub("'", "''")}' " \
        "AND timestamp > now() - INTERVAL 15 MINUTE"
      )
      rows.first.to_h["c"].to_i.positive?
    rescue StandardError
      false
    end
  end
end
