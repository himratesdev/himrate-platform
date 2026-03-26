# frozen_string_literal: true

require "rails_helper"

RSpec.describe "API Scaffold", type: :request do
  let(:user) { create(:user, role: "viewer", tier: "free") }
  let(:token) { Auth::JwtService.encode_access(user.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}" } }
  let(:channel) { create(:channel) }
  let(:watchlist) { create(:watchlist, user: user) }

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
      get "/api/v1/channels/#{channel.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-003: GET /channels/:id/trust → 200 (guest-accessible headline)
  describe "GET /api/v1/channels/:id/trust" do
    it "returns placeholder" do
      get "/api/v1/channels/#{channel.id}/trust", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-004: GET /channels/:id/streams → 403 (Free without post-stream window)
  describe "GET /api/v1/channels/:id/streams" do
    it "returns 403 for free user without active stream window" do
      get "/api/v1/channels/#{channel.id}/streams", headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  # TC-005: GET /channels/:id/bot-chain → 200 (basic access for all)
  describe "GET /api/v1/channels/:id/bot-chain" do
    it "returns placeholder" do
      get "/api/v1/channels/#{channel.id}/bot-chain", headers: auth_headers
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

  # TC-012: GET /channels/:id/streams/:id → 403 (Free without window)
  describe "GET /api/v1/channels/:id/streams/:id" do
    it "returns 403 for free user without active stream window" do
      stream = create(:stream, channel: channel, started_at: 2.days.ago, ended_at: 2.days.ago)
      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}", headers: auth_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  # TC-013: DELETE /subscriptions/:id → 200
  describe "DELETE /api/v1/subscriptions/:id" do
    it "returns placeholder" do
      subscription = create(:subscription, user: user)
      delete "/api/v1/subscriptions/#{subscription.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
    end
  end

  # TC-014: DELETE /watchlists/:id → 200
  describe "DELETE /api/v1/watchlists/:id" do
    it "returns placeholder" do
      delete "/api/v1/watchlists/#{watchlist.id}", headers: auth_headers
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
