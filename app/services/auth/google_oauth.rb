# frozen_string_literal: true

module Auth
  class GoogleOauth
    AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    USERINFO_URL = "https://www.googleapis.com/oauth2/v3/userinfo"
    SCOPES = "openid email profile"

    def initialize
      @client_id = ENV.fetch("GOOGLE_CLIENT_ID")
      @client_secret = ENV.fetch("GOOGLE_CLIENT_SECRET")
      @redirect_uri = ENV.fetch("GOOGLE_REDIRECT_URI")
    end

    # FR-001: Generate redirect URL
    def authorize_url
      state = SecureRandom.hex(32)

      url = "#{AUTHORIZE_URL}?" + {
        client_id: @client_id,
        redirect_uri: @redirect_uri,
        response_type: "code",
        scope: SCOPES,
        state: state,
        access_type: "offline",
        prompt: "consent"
      }.to_query

      { redirect_url: url, state: state }
    end

    # FR-002: Exchange code for tokens + get user info
    def callback(code:)
      tokens = exchange_code(code)
      user_info = fetch_user_info(tokens[:access_token])

      find_or_create_user(user_info, tokens)
    end

    private

    def exchange_code(code)
      response = HTTP.timeout(10).post(TOKEN_URL, form: {
        client_id: @client_id,
        client_secret: @client_secret,
        code: code,
        grant_type: "authorization_code",
        redirect_uri: @redirect_uri
      })

      raise Auth::AuthError, "Google token exchange failed: #{response.status}" unless response.status.success?

      JSON.parse(response.body, symbolize_names: true)
    end

    def fetch_user_info(access_token)
      response = HTTP.timeout(5)
        .auth("Bearer #{access_token}")
        .get(USERINFO_URL)

      raise Auth::AuthError, "Google userinfo fetch failed: #{response.status}" unless response.status.success?

      JSON.parse(response.body, symbolize_names: true)
    end

    # FR-003 + FR-004: Atomic find_or_create
    def find_or_create_user(google_user, tokens)
      ActiveRecord::Base.transaction do
        auth_provider = AuthProvider.find_by(
          provider: "google",
          provider_id: google_user[:sub]
        )

        if auth_provider
          update_attrs = { access_token: tokens[:access_token] }
          update_attrs[:refresh_token] = tokens[:refresh_token] if tokens[:refresh_token].present?
          update_attrs[:expires_at] = Time.current + tokens[:expires_in].to_i.seconds
          auth_provider.update!(update_attrs)
          auth_provider.user
        else
          user = User.create!(
            email: google_user[:email],
            username: derive_username(google_user),
            role: "viewer",
            tier: "free"
          )

          AuthProvider.create!(
            user: user,
            provider: "google",
            provider_id: google_user[:sub],
            access_token: tokens[:access_token],
            refresh_token: tokens[:refresh_token],
            expires_at: Time.current + tokens[:expires_in].to_i.seconds,
            is_broadcaster: false
          )

          user
        end
      end
    rescue ActiveRecord::RecordNotUnique => e
      @retry_count = (@retry_count || 0) + 1
      raise e if @retry_count > 1
      retry
    end

    def derive_username(google_user)
      base = google_user[:name].presence || google_user[:email]&.split("@")&.first || "google_user"
      "#{base}_#{google_user[:sub][-6..]}"
    end
  end
end
