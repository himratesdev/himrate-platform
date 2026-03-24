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
      Rails.cache.write("pkce:#{state}", "test_verifier")

      # Mock Twitch token exchange
      stub_request(:post, "https://id.twitch.tv/oauth2/token")
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
  end

  # T-003: Callback creates user + auth_provider
  describe "GET /api/v1/auth/twitch/callback (user creation)" do
    before do
      Rails.cache.write("pkce:create_state", "verifier")

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
      Rails.cache.write("pkce:nodup_state", "verifier")

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
      Rails.cache.write("pkce:streamer_state", "verifier")

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
      Rails.cache.write("pkce:viewer_state", "verifier")

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
end
