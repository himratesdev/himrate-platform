# frozen_string_literal: true

# Shared helper for the external lane: app-credential gate + resolve a currently-live channel.
#
# Credential gate lives here (not duplicated per spec) so the "half-configured" case has ONE
# definition: Helix needs BOTH id and secret — HelixClient#initialize raises on a missing secret,
# so checking only the id (as the first cut did) turned the credential-free GQL/IRC specs into
# hard errors whenever CI had an id but no secret (the real nightly shape when only one secret
# is configured).
module ExternalLiveChannel
  FALLBACKS = %w[zackrawrr caseoh_ kaicenat jasontheween].freeze

  # Real app credentials present? (`test_client_id` is the CI placeholder from ci.yml.)
  def self.app_creds?
    ENV["TWITCH_CLIENT_ID"].present? &&
      ENV["TWITCH_CLIENT_SECRET"].present? &&
      ENV["TWITCH_CLIENT_ID"] != "test_client_id"
  end

  # Live channel login, or nil. Helix first when credentials allow it; any failure (bad creds,
  # revoked token, Twitch 5xx) degrades to the keyless path rather than failing the caller —
  # the GQL/IRC specs are credential-free by design and must not inherit a Helix outage.
  def self.pick
    helix_pick || keyless_pick
  end

  def self.helix_pick
    return nil unless app_creds?

    Twitch::HelixClient.new.get_streams(first: 1)&.first&.dig("user_login").presence
  rescue StandardError
    nil
  end

  # Keyless probe: bot_check's persisted query may omit the stream field, so liveness is
  # probed via community_tab (a live channel has a chatters roster; offline returns nil).
  def self.keyless_pick
    gql = Twitch::GqlClient.new
    FALLBACKS.find do |l|
      (gql.community_tab(channel_login: l)&.dig(:total_present) || 0).positive?
    rescue StandardError
      false
    end
  end
end
