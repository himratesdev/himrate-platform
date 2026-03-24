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

  # T-010: OAuth denied
  describe "GET /api/v1/auth/twitch/callback with error" do
    it "returns 401 when user denied" do
      get "/api/v1/auth/twitch/callback", params: { error: "access_denied", state: "test" }

      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("TWITCH_AUTH_DENIED")
    end
  end

  # T-009: DELETE /api/v1/auth/logout
  describe "DELETE /api/v1/auth/logout" do
    it "deactivates session" do
      user = User.create!(username: "test_user", role: "viewer", tier: "free")
      session = Session.create!(user: user, token: SecureRandom.hex, expires_at: 1.day.from_now)
      token = Auth::JwtService.encode_access(user.id)

      delete "/api/v1/auth/logout", headers: { "Authorization" => "Bearer #{token}" }

      expect(response).to have_http_status(:ok)
      expect(session.reload.is_active).to be false
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

  # T-008: POST /api/v1/auth/refresh with expired token
  describe "POST /api/v1/auth/refresh with invalid token" do
    it "returns 401" do
      post "/api/v1/auth/refresh", params: { refresh_token: "invalid.token" }

      expect(response).to have_http_status(:unauthorized)
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
