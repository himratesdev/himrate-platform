# frozen_string_literal: true

module Me
  # Resolve a Twitch login → Channel and record that the viewer opened it (screen 01). Returns a
  # Result; CHANNEL_NOT_FOUND when the login has no Channel row (opened a channel we don't track).
  class TrackRecentChannel
    Result = Struct.new(:ok, :error, :record, keyword_init: true)

    def initialize(user:, login:)
      @user = user
      @login = login.to_s.strip.downcase
    end

    def call
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") if @login.blank?

      channel = Channel.find_by(login: @login)
      return Result.new(ok: false, error: "CHANNEL_NOT_FOUND") if channel.nil?

      Result.new(ok: true, record: RecentChannel.track(user: @user, channel: channel))
    end
  end
end
