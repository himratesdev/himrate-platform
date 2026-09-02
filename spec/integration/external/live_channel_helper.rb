# frozen_string_literal: true

# Shared helper for the external lane: resolve a currently-live channel login.
# Prefers a real Helix /streams call (app creds), falls back to perennially-large channels.
module ExternalLiveChannel
  FALLBACKS = %w[zackrawrr caseoh_ kaicenat jasontheween].freeze

  def self.pick
    if ENV["TWITCH_CLIENT_ID"].present? && ENV["TWITCH_CLIENT_ID"] != "test_client_id"
      streams = Twitch::HelixClient.new.get_streams(first: 1)
      login = streams&.first&.dig("user_login")
      return login if login.present?
    end
    # Keyless probe: bot_check's persisted query may omit the stream field, so liveness is
    # probed via community_tab (a live channel has a chatters roster; offline returns nil).
    gql = Twitch::GqlClient.new
    FALLBACKS.find do |l|
      (gql.community_tab(channel_login: l)&.dig(:total_present) || 0).positive?
    rescue StandardError
      false
    end
  end
end
