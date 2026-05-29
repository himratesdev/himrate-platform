# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth API", type: :request do
  # T-001: POST /api/v1/auth/twitch → redirect URL with PKCE
  describe "POST /api/v1/auth/twitch" do
    it "returns redirect URL with code_challenge" do
      post "/api/v1/auth/twitch"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["redirect_url"]).to include("id.twitch.tv")
      expect(body["redirect_url"]).to include("code_challenge=")
      expect(body["redirect_url"]).to include("code_challenge_method=S256")
      expect(body["state"]).to be_present
    end
  end

  # T-002: Callback happy path → JWT
  describe "GET /api/v1/auth/twitch/callback (happy path)" do
    before do
      state = "test_state_123"
      Rails.cache.write("pkce:#{state}", { code_verifier: "test_verifier", redirect_uri: ENV.fetch("TWITCH_REDIRECT_URI") })

      # Mock Twitch token exchange — assert the exchange uses the state-bound redirect_uri (BUG-027)
      stub_request(:post, "https://id.twitch.tv/oauth2/token")
        .with(body: hash_including("redirect_uri" => ENV.fetch("TWITCH_REDIRECT_URI")))
        .to_return(
          status: 200,
          body: { access_token: "twitch_at", refresh_token: "twitch_rt", expires_in: 14400 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      # Mock Twitch user info
      stub_request(:get, "https://api.twitch.tv/helix/users")
        .to_return(
          status: 200,
          body: { data: [ { id: "12345", login: "teststreamer", email: "test@twitch.tv", broadcaster_type: "" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns JWT tokens and creates user" do
      get "/api/v1/auth/twitch/callback", params: { code: "auth_code", state: "test_state_123" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
      expect(body["expires_in"]).to eq(3600)
      expect(body["user"]["username"]).to eq("teststreamer")
      expect(body["user"]["role"]).to eq("viewer")
    end

    # BUG-USER-PAYLOAD-TWITCH-LINKED (2026-05-29) regression — extension SidePanel banner
    # «Привяжите Twitch для точной аналитики» reads authState.twitchLinked. Pre-fix payload
    # omitted twitch_linked / twitch_login / google_linked → SidePanel defaulted false →
    # banner shown to every Twitch-logged-in user on tracked channels. Lock the new shape.
    it "exposes twitch_linked / twitch_login / google_linked в user payload" do
      get "/api/v1/auth/twitch/callback", params: { code: "auth_code", state: "test_state_123" }

      body = JSON.parse(response.body)
      expect(body["user"]["twitch_linked"]).to eq(true)
      expect(body["user"]["twitch_login"]).to eq("teststreamer")
      expect(body["user"]["google_linked"]).to eq(false)
    end
  end

  # T-003: Callback creates user + auth_provider
  describe "GET /api/v1/auth/twitch/callback (user creation)" do
    before do
      Rails.cache.write("pkce:create_state", { code_verifier: "verifier", redirect_uri: ENV.fetch("TWITCH_REDIRECT_URI") })

      stub_request(:post, "https://id.twitch.tv/oauth2/token")
        .to_return(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 14400 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://api.twitch.tv/helix/users")
        .to_return(status: 200, body: { data: [ { id: "99999", login: "newuser", email: "new@test.tv", broadcaster_type: "" } ] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "creates User and AuthProvider" do
      expect {
        get "/api/v1/auth/twitch/callback", params: { code: "code", state: "create_state" }
      }.to change(User, :count).by(1).and change(AuthProvider, :count).by(1)
    end
  end

  # T-004: Repeated callback does not duplicate user
  describe "GET /api/v1/auth/twitch/callback (no duplicate)" do
    let!(:existing_user) { User.create!(username: "returning", role: "viewer", tier: "free") }
    let!(:existing_auth) { AuthProvider.create!(user: existing_user, provider: "twitch", provider_id: "77777", access_token: "old", refresh_token: "old", is_broadcaster: false) }

    before do
      Rails.cache.write("pkce:nodup_state", { code_verifier: "verifier", redirect_uri: ENV.fetch("TWITCH_REDIRECT_URI") })

      stub_request(:post, "https://id.twitch.tv/oauth2/token")
        .to_return(status: 200, body: { access_token: "new_at", refresh_token: "new_rt", expires_in: 14400 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://api.twitch.tv/helix/users")
        .to_return(status: 200, body: { data: [ { id: "77777", login: "returning", email: "ret@test.tv", broadcaster_type: "" } ] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "does not create new user" do
      expect {
        get "/api/v1/auth/twitch/callback", params: { code: "code", state: "nodup_state" }
      }.not_to change(User, :count)
    end
  end

  # T-005: Streamer (affiliate) → role: streamer
  describe "GET /api/v1/auth/twitch/callback (streamer)" do
    before do
      Rails.cache.write("pkce:streamer_state", { code_verifier: "verifier", redirect_uri: ENV.fetch("TWITCH_REDIRECT_URI") })

      stub_request(:post, "https://id.twitch.tv/oauth2/token")
        .to_return(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 14400 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://api.twitch.tv/helix/users")
        .to_return(status: 200, body: { data: [ { id: "55555", login: "affiliatestreamer", email: "s@test.tv", broadcaster_type: "affiliate" } ] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "sets role to streamer" do
      get "/api/v1/auth/twitch/callback", params: { code: "code", state: "streamer_state" }

      body = JSON.parse(response.body)
      expect(body["user"]["role"]).to eq("streamer")
    end
  end

  # T-006: Viewer → role stays viewer
  describe "GET /api/v1/auth/twitch/callback (viewer)" do
    before do
      Rails.cache.write("pkce:viewer_state", { code_verifier: "verifier", redirect_uri: ENV.fetch("TWITCH_REDIRECT_URI") })

      stub_request(:post, "https://id.twitch.tv/oauth2/token")
        .to_return(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 14400 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://api.twitch.tv/helix/users")
        .to_return(status: 200, body: { data: [ { id: "66666", login: "justviewer", email: "v@test.tv", broadcaster_type: "" } ] }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "sets role to viewer" do
      get "/api/v1/auth/twitch/callback", params: { code: "code", state: "viewer_state" }

      body = JSON.parse(response.body)
      expect(body["user"]["role"]).to eq("viewer")
    end
  end

  # T-007: POST /api/v1/auth/refresh with valid token
  describe "POST /api/v1/auth/refresh" do
    it "returns new tokens" do
      user = User.create!(username: "refresh_user", role: "viewer", tier: "free")
      refresh = Auth::JwtService.encode_refresh(user.id)

      post "/api/v1/auth/refresh", params: { refresh_token: refresh }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
    end
  end

  # T-008: POST /api/v1/auth/refresh with expired/invalid token
  describe "POST /api/v1/auth/refresh with invalid token" do
    it "returns 401" do
      post "/api/v1/auth/refresh", params: { refresh_token: "invalid.token" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # Nit #8: refresh with blank token
  describe "POST /api/v1/auth/refresh with blank token" do
    it "returns 401" do
      post "/api/v1/auth/refresh", params: { refresh_token: "" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # T-009: DELETE /api/v1/auth/logout
  describe "DELETE /api/v1/auth/logout" do
    it "deactivates session" do
      user = User.create!(username: "logout_user", role: "viewer", tier: "free")
      session_record = Session.create!(user: user, token: SecureRandom.hex, expires_at: 1.day.from_now)
      token = Auth::JwtService.encode_access(user.id)

      delete "/api/v1/auth/logout", headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(session_record.reload.is_active).to be false
    end
  end

  # T-010: OAuth denied
  describe "GET /api/v1/auth/twitch/callback with error" do
    it "returns 401 when user denied" do
      get "/api/v1/auth/twitch/callback", params: { error: "access_denied", state: "test" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("TWITCH_AUTH_DENIED")
    end
  end

  # T-011: JWT forgery
  describe "DELETE /api/v1/auth/logout with forged token" do
    it "returns 401" do
      delete "/api/v1/auth/logout", headers: { "Authorization" => "Bearer forged.jwt.token" }

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # BUG-027: extension flow — allowlisted client redirect_uri baked into authorize URL
  describe "POST /api/v1/auth/twitch with extension redirect_uri (allowlisted)" do
    let(:ext_uri) { "https://gnnhhopjghkjdbjafhefmbckakbjkabp.chromiumapp.org/" }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("OAUTH_ALLOWED_REDIRECT_URIS", "").and_return(ext_uri)
    end

    it "uses the supplied redirect_uri in the authorize URL" do
      post "/api/v1/auth/twitch", params: { redirect_uri: ext_uri }

      expect(response).to have_http_status(:ok)
      redirect_url = JSON.parse(response.body)["redirect_url"]
      query = Rack::Utils.parse_query(URI(redirect_url).query)
      expect(query["redirect_uri"]).to eq(ext_uri)
    end
  end

  # BUG-027: untrusted redirect_uri rejected (open-redirect guard)
  describe "POST /api/v1/auth/twitch with disallowed redirect_uri" do
    it "returns 400 INVALID_REDIRECT_URI" do
      post "/api/v1/auth/twitch", params: { redirect_uri: "https://evil.example.com/steal" }

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["error"]).to eq("INVALID_REDIRECT_URI")
    end
  end

  # BUG-OAUTH-MV3: Chrome MV3 extension OAuth callback redirect flow.
  # POST /api/v1/auth/twitch accepts extension_redirect (chromiumapp.org URL); when
  # provided, twitch_callback 302-redirects к нему с tokens encoded в URL payload.
  describe "Chrome MV3 extension OAuth flow (extension_redirect)" do
    let(:ext_redirect) { "https://gnnhhopjghkjdbjafhefmbckakbjkabp.chromiumapp.org/" }

    it "POST /auth/twitch caches extension_redirect when supplied" do
      post "/api/v1/auth/twitch", params: { extension_redirect: ext_redirect }
      expect(response).to have_http_status(:ok)
      state = JSON.parse(response.body)["state"]
      cached = Rails.cache.read("pkce:#{state}")
      expect(cached[:extension_redirect]).to eq(ext_redirect)
    end

    it "POST /auth/twitch rejects malformed extension_redirect (silently — caches nil)" do
      post "/api/v1/auth/twitch", params: { extension_redirect: "https://evil.example.com/" }
      expect(response).to have_http_status(:ok)
      state = JSON.parse(response.body)["state"]
      cached = Rails.cache.read("pkce:#{state}")
      expect(cached[:extension_redirect]).to be_nil
    end

    it "POST /auth/twitch rejects wrong-length chromiumapp.org id (silently)" do
      bad = "https://short.chromiumapp.org/"
      post "/api/v1/auth/twitch", params: { extension_redirect: bad }
      expect(response).to have_http_status(:ok)
      state = JSON.parse(response.body)["state"]
      cached = Rails.cache.read("pkce:#{state}")
      expect(cached[:extension_redirect]).to be_nil
    end

    it 'filter_redirect config matches chromiumapp.org pattern (MF-1 regression guard)' do
      # MF-1 regression: Rails `ActionController::Redirecting` writes "Redirected to <URL>"
      # via `instrument_redirect`. Rails applies `config.filter_redirect` patterns at emit
      # time, replacing matching URLs с "[FILTERED]". Without the chromiumapp.org pattern,
      # the JWT payload в redirect query string lands в Loki / on-disk logs.
      #
      # Asserts the pattern is registered AND would actually match a real
      # chrome.identity.getRedirectURL()-shape URL. ActionDispatch performs substitution
      # at log emit time using Regexp#match? on `Location` header. If регулярка stops
      # matching → log line leaks payload.
      patterns = Rails.application.config.filter_redirect
      chromiumapp_pattern = patterns.find { |p| p.is_a?(Regexp) && p.source.include?("chromiumapp") }
      expect(chromiumapp_pattern).to be_present, "filter_redirect missing chromiumapp.org pattern"

      sample_url = "https://gnnhhopjghkjdbjafhefmbckakbjkabp.chromiumapp.org/?payload=eyJhY2Nlc3NfdG9rZW4iOiJleEpoYkdjaSJ9"
      expect(chromiumapp_pattern).to match(sample_url)
    end

    it "GET /auth/twitch/callback redirects к extension_redirect с base64 payload когда cached" do
      Rails.cache.write(
        "pkce:ext_state",
        {
          code_verifier: "test_verifier",
          redirect_uri: ENV.fetch("TWITCH_REDIRECT_URI"),
          extension_redirect: ext_redirect
        },
        expires_in: 10.minutes
      )

      stub_request(:post, "https://id.twitch.tv/oauth2/token")
        .to_return(
          status: 200,
          body: { access_token: "twitch_access", refresh_token: "twitch_refresh", expires_in: 14400, scope: %w[user:read:email] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://api.twitch.tv/helix/users")
        .to_return(
          status: 200,
          body: { data: [ { id: "twitch_user_999", login: "ext_test_user", email: "ext@test.com", display_name: "Ext Test" } ] }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      get "/api/v1/auth/twitch/callback", params: { code: "test_code", state: "ext_state" }

      expect(response).to have_http_status(:found) # 302
      location = response.headers["Location"]
      expect(location).to start_with(ext_redirect)
      expect(location).to include("payload=")

      payload_param = Rack::Utils.parse_query(URI(location).query)["payload"]
      decoded = JSON.parse(Base64.urlsafe_decode64(payload_param))
      expect(decoded["access_token"]).to be_present
      expect(decoded["refresh_token"]).to be_present
      expect(decoded["user"]["username"]).to eq("ext_test_user")
    end
  end
end
