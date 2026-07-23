# frozen_string_literal: true

module Auth
  # YouTube connect-flow (SA-2 demographics): incremental OAuth that grants HimRate read access to a
  # streamer's YouTube Analytics (measured age×gender×country). Reuses the Google OAuth CLIENT
  # (GOOGLE_CLIENT_ID/SECRET) but requests the `yt-analytics.readonly` scope + offline access, so the
  # stored refresh token lets a worker call the Analytics API on the streamer's behalf.
  #
  # DISTINCT from Google LOGIN (`Auth::GoogleOauth`, scope openid/email/profile): this ATTACHES a
  # "youtube" AuthProvider to an ALREADY logged-in user — it never creates a user. The callback binds to
  # the initiating user via a signed state cached server-side (never trusts the browser for identity).
  class YoutubeOauth
    AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    CHANNEL_URL = "https://www.googleapis.com/youtube/v3/channels?part=id,snippet&mine=true"
    SCOPES = "openid https://www.googleapis.com/auth/yt-analytics.readonly"
    PROVIDER = "youtube"

    def initialize
      @client_id = ENV.fetch("GOOGLE_CLIENT_ID")
      @client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET")
      # Derive the youtube callback from the registered google one (same host per env) — no new env var.
      @redirect_uri = ENV.fetch("GOOGLE_REDIRECT_URI").sub("/auth/google/callback", "/auth/youtube/callback")
    end

    attr_reader :redirect_uri

    def authorize_url(state:)
      "#{AUTHORIZE_URL}?" + {
        client_id: @client_id, redirect_uri: @redirect_uri, response_type: "code",
        scope: SCOPES, state: state,
        access_type: "offline",           # → a refresh token we can reuse for Analytics polls
        prompt: "consent",                # force the refresh token even on re-consent
        include_granted_scopes: "true"    # keep the login grant (incremental auth)
      }.to_query
    end

    # Exchange the code, resolve the connecting YouTube channel id, and persist the connection as a
    # "youtube" AuthProvider on `user`. Raises Auth::AuthError on token failure; ActiveRecord::RecordNotUnique
    # if that YouTube channel is already connected to a DIFFERENT HimRate user (the caller surfaces it).
    def connect!(code:, user:)
      tokens = exchange_code(code)
      channel_id = fetch_channel_id(tokens[:access_token])
      store(user, tokens, channel_id)
    end

    private

    def exchange_code(code)
      response = HTTP.timeout(10).post(TOKEN_URL, form: {
        client_id: @client_id, client_secret: @client_secret, code: code,
        grant_type: "authorization_code", redirect_uri: @redirect_uri
      })
      raise Auth::AuthError, "YouTube token exchange failed: #{response.status}" unless response.status.success?

      JSON.parse(response.body, symbolize_names: true)
    end

    def fetch_channel_id(access_token)
      response = HTTP.timeout(5).auth("Bearer #{access_token}").get(CHANNEL_URL)
      return nil unless response.status.success?

      JSON.parse(response.body, symbolize_names: true).dig(:items, 0, :id)
    end

    def store(user, tokens, channel_id)
      provider = AuthProvider.find_or_initialize_by(user: user, provider: PROVIDER)
      provider.provider_id = channel_id.presence || provider.provider_id.presence || "user:#{user.id}"
      provider.access_token = tokens[:access_token]
      provider.refresh_token = tokens[:refresh_token] if tokens[:refresh_token].present?
      provider.expires_at = Time.current + tokens[:expires_in].to_i.seconds
      provider.scopes = SCOPES.split
      provider.save!
      provider
    end
  end
end
