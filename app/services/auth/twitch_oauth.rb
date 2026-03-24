# frozen_string_literal: true

module Auth
  class TwitchOauth
    AUTHORIZE_URL = "https://id.twitch.tv/oauth2/authorize"
    TOKEN_URL = "https://id.twitch.tv/oauth2/token"
    USER_URL = "https://api.twitch.tv/helix/users"
    SCOPES = "user:read:email channel:read:subscriptions"

    def initialize
      @client_id = ENV.fetch("TWITCH_CLIENT_ID")
      @client_secret = ENV.fetch("TWITCH_CLIENT_SECRET")
      @redirect_uri = ENV.fetch("TWITCH_REDIRECT_URI")
    end

    # FR-001: Generate PKCE + redirect URL
    def authorize_url
      code_verifier = SecureRandom.urlsafe_base64(96)
      code_challenge = Base64.urlsafe_encode64(
        Digest::SHA256.digest(code_verifier), padding: false
      )
      state = SecureRandom.hex(32)

      url = "#{AUTHORIZE_URL}?" + {
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        response_type: "code",
        scope: SCOPES,
        code_challenge: code_challenge,
        code_challenge_method: "S256",
        state: state
      }.to_query

      { redirect_url: url, code_verifier: code_verifier, state: state }
    end

    # FR-002: Exchange code for tokens + get user info
    def callback(code:, code_verifier:)
      tokens = exchange_code(code, code_verifier)
      user_info = fetch_user_info(tokens[:access_token])

      find_or_create_user(user_info, tokens)
    end

    private

    def exchange_code(code, code_verifier)
      response = HTTP.timeout(5).post(TOKEN_URL, form: {
        client_id: @client_id,
        client_secret: @client_secret,
        code: code,
        grant_type: "authorization_code",
        redirect_uri: @redirect_uri,
        code_verifier: code_verifier
      })

      raise Auth::JwtService::AuthError, "Twitch token exchange failed: #{response.status}" unless response.status.success?

      JSON.parse(response.body, symbolize_names: true)
    end

    def fetch_user_info(access_token)
      response = HTTP.timeout(5)
        .auth("Bearer #{access_token}")
        .headers("Client-Id" => @client_id)
        .get(USER_URL)

      raise Auth::JwtService::AuthError, "Twitch user fetch failed: #{response.status}" unless response.status.success?

      JSON.parse(response.body, symbolize_names: true)[:data].first
    end

    # FR-005: Auto-create user + FR-006: Streamer Mode
    def find_or_create_user(twitch_user, tokens)
      auth_provider = AuthProvider.find_by(
        provider: "twitch",
        provider_id: twitch_user[:id]
      )

      if auth_provider
        # Existing user — update tokens
        auth_provider.update!(
          access_token: tokens[:access_token],
          refresh_token: tokens[:refresh_token],
          expires_at: Time.current + tokens[:expires_in].to_i.seconds,
          scopes: SCOPES.split(" ")
        )
        user = auth_provider.user
      else
        # New user — create
        user = User.create!(
          email: twitch_user[:email],
          username: twitch_user[:login],
          role: determine_role(twitch_user[:broadcaster_type]),
          tier: "free"
        )

        AuthProvider.create!(
          user: user,
          provider: "twitch",
          provider_id: twitch_user[:id],
          access_token: tokens[:access_token],
          refresh_token: tokens[:refresh_token],
          expires_at: Time.current + tokens[:expires_in].to_i.seconds,
          scopes: SCOPES.split(" "),
          is_broadcaster: streamer?(twitch_user[:broadcaster_type])
        )
      end

      # FR-006: Update role if broadcaster status changed
      if streamer?(twitch_user[:broadcaster_type]) && user.role != "streamer"
        user.update!(role: "streamer")
      end

      user
    end

    def determine_role(broadcaster_type)
      streamer?(broadcaster_type) ? "streamer" : "viewer"
    end

    def streamer?(broadcaster_type)
      broadcaster_type.in?(%w[affiliate partner])
    end
  end
end
