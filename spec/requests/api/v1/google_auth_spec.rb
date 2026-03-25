# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Google Auth API", type: :request do
  # TC-001: POST /api/v1/auth/google → redirect URL
  describe "POST /api/v1/auth/google" do
    it "returns redirect URL with scopes" do
      post "/api/v1/auth/google"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["redirect_url"]).to include("accounts.google.com")
      expect(body["redirect_url"]).to include("scope=openid")
      expect(body["redirect_url"]).to include("email")
      expect(body["redirect_url"]).to include("profile")
      expect(body["redirect_url"]).to include("access_type=offline")
      expect(body["state"]).to be_present
    end
  end

  # TC-002: Callback happy path → JWT + user created
  describe "GET /api/v1/auth/google/callback (happy path)" do
    before do
      state = "test_google_state"
      Rails.cache.write("google_state:#{state}", "valid")

      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(
          status: 200,
          body: { access_token: "google_at", refresh_token: "google_rt", expires_in: 3600 }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      stub_request(:get, "https://www.googleapis.com/oauth2/v3/userinfo")
        .to_return(
          status: 200,
          body: { sub: "google_123", email: "test@gmail.com", name: "Test User", picture: "https://photo.url" }.to_json,
          headers: { "Content-Type" => "application/json" }
        )
    end

    it "returns JWT tokens and creates user" do
      get "/api/v1/auth/google/callback", params: { code: "auth_code", state: "test_google_state" }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
      expect(body["expires_in"]).to eq(3600)
      expect(body["user"]["username"]).to start_with("Test User_")
      expect(body["user"]["role"]).to eq("viewer")
      expect(body["user"]["email"]).to eq("test@gmail.com")
    end
  end

  # TC-003: Callback existing user → no duplicate
  describe "GET /api/v1/auth/google/callback (no duplicate)" do
    let!(:existing_user) { User.create!(username: "googleuser", role: "viewer", tier: "free") }
    let!(:existing_auth) { AuthProvider.create!(user: existing_user, provider: "google", provider_id: "google_existing", access_token: "old", refresh_token: "old", is_broadcaster: false) }

    before do
      Rails.cache.write("google_state:nodup_state", "valid")

      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 200, body: { access_token: "new_at", refresh_token: "new_rt", expires_in: 3600 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://www.googleapis.com/oauth2/v3/userinfo")
        .to_return(status: 200, body: { sub: "google_existing", email: "existing@gmail.com", name: "Existing" }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "does not create new user" do
      expect {
        get "/api/v1/auth/google/callback", params: { code: "code", state: "nodup_state" }
      }.not_to change(User, :count)
    end
  end

  # TC-004: Callback with error → 401
  describe "GET /api/v1/auth/google/callback with error" do
    it "returns 401 when user denied" do
      get "/api/v1/auth/google/callback", params: { error: "access_denied", state: "test" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("GOOGLE_AUTH_DENIED")
    end
  end

  # TC-005: Callback state mismatch → 401
  describe "GET /api/v1/auth/google/callback with invalid state" do
    it "returns 401 for invalid state" do
      get "/api/v1/auth/google/callback", params: { code: "code", state: "invalid_state" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("INVALID_STATE")
    end
  end

  # TC-006: Refresh with Google JWT
  describe "POST /api/v1/auth/refresh with Google user" do
    it "returns new tokens" do
      user = User.create!(username: "google_refresh", role: "viewer", tier: "free")
      refresh = Auth::JwtService.encode_refresh(user.id)

      post "/api/v1/auth/refresh", params: { refresh_token: refresh }

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
    end
  end

  # TC-007: Logout with Google JWT
  describe "DELETE /api/v1/auth/logout with Google user" do
    it "deactivates session" do
      user = User.create!(username: "google_logout", role: "viewer", tier: "free")
      session_record = Session.create!(user: user, token: SecureRandom.hex, expires_at: 1.day.from_now)
      token = Auth::JwtService.encode_access(user.id)

      delete "/api/v1/auth/logout", headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(session_record.reload.is_active).to be false
    end
  end

  # TC-008: Google user role is always viewer
  describe "GET /api/v1/auth/google/callback (role = viewer)" do
    before do
      Rails.cache.write("google_state:role_state", "valid")

      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 3600 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://www.googleapis.com/oauth2/v3/userinfo")
        .to_return(status: 200, body: { sub: "google_role", email: "role@gmail.com", name: "RoleUser" }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "always sets role to viewer" do
      get "/api/v1/auth/google/callback", params: { code: "code", state: "role_state" }

      body = JSON.parse(response.body)
      expect(body["user"]["role"]).to eq("viewer")
    end
  end

  # TC-009: Cross-provider email collision → 409
  describe "GET /api/v1/auth/google/callback (email collision)" do
    let!(:twitch_user) { User.create!(username: "twitch_user", email: "shared@gmail.com", role: "viewer", tier: "free") }
    let!(:twitch_auth) { AuthProvider.create!(user: twitch_user, provider: "twitch", provider_id: "twitch_123", access_token: "at", refresh_token: "rt", is_broadcaster: false) }

    before do
      Rails.cache.write("google_state:collision_state", "valid")

      stub_request(:post, "https://oauth2.googleapis.com/token")
        .to_return(status: 200, body: { access_token: "at", refresh_token: "rt", expires_in: 3600 }.to_json, headers: { "Content-Type" => "application/json" })

      stub_request(:get, "https://www.googleapis.com/oauth2/v3/userinfo")
        .to_return(status: 200, body: { sub: "google_collision", email: "shared@gmail.com", name: "Collision User" }.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "returns 409 when email exists with another provider" do
      get "/api/v1/auth/google/callback", params: { code: "code", state: "collision_state" }

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("EMAIL_ALREADY_EXISTS")
    end
  end
end
