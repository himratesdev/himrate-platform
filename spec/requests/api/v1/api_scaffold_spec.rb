# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API Scaffold", type: :request do
  let(:user) { User.create!(username: "testuser", role: "viewer", tier: "free") }
  let(:token) { Auth::JwtService.encode_access(user.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}" } }

  # TC-001: GET /channels → 200
  describe "GET /api/v1/channels" do
    it "returns placeholder with auth" do
      get "/api/v1/channels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["meta"]["status"]).to eq("not_implemented")
    end
  end

  # TC-002: GET /channels/:id → 200
  describe "GET /api/v1/channels/:id" do
    it "returns placeholder" do
      get "/api/v1/channels/123", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-003: GET /channels/:id/trust → 200
  describe "GET /api/v1/channels/:id/trust" do
    it "returns placeholder" do
      get "/api/v1/channels/123/trust", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-004: GET /channels/:id/streams → 200
  describe "GET /api/v1/channels/:id/streams" do
    it "returns placeholder" do
      get "/api/v1/channels/123/streams", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-005: GET /channels/:id/bot-chain → 200
  describe "GET /api/v1/channels/:id/bot-chain" do
    it "returns placeholder" do
      get "/api/v1/channels/123/bot-chain", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-006: GET /subscriptions → 200
  describe "GET /api/v1/subscriptions" do
    it "returns placeholder" do
      get "/api/v1/subscriptions", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-007: POST /subscriptions → 200
  describe "POST /api/v1/subscriptions" do
    it "returns placeholder" do
      post "/api/v1/subscriptions", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-008: GET /watchlists → 200
  describe "GET /api/v1/watchlists" do
    it "returns placeholder" do
      get "/api/v1/watchlists", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-009: POST /webhooks/twitch → 200 (public)
  describe "POST /webhooks/twitch" do
    it "returns placeholder without auth" do
      post "/webhooks/twitch"
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-012: GET /channels/:id/streams/:id → 200
  describe "GET /api/v1/channels/:id/streams/:id" do
    it "returns placeholder" do
      get "/api/v1/channels/123/streams/456", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-013: DELETE /subscriptions/:id → 200
  describe "DELETE /api/v1/subscriptions/:id" do
    it "returns placeholder" do
      delete "/api/v1/subscriptions/123", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-014: DELETE /watchlists/:id → 200
  describe "DELETE /api/v1/watchlists/:id" do
    it "returns placeholder" do
      delete "/api/v1/watchlists/123", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-010: GET /channels without token → 401
  describe "GET /api/v1/channels without auth" do
    it "returns 401" do
      get "/api/v1/channels"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  # TC-011: POST /webhooks/twitch without token → 200 (public)
  describe "POST /webhooks/twitch without auth" do
    it "returns 200 (public endpoint)" do
      post "/webhooks/twitch"
      expect(response).to have_http_status(:ok)
    end
  end
end
