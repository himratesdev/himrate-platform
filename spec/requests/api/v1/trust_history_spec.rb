# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trust History API" do
  let(:channel) { create(:channel) }
  let(:user) { create(:user) }

  describe "GET /api/v1/channels/:id/trust/history" do
    it "returns 403 for guest (no auth)" do
      get "/api/v1/channels/#{channel.id}/trust/history"
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 30m data for registered user" do
      get "/api/v1/channels/#{channel.id}/trust/history", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)

      data = response.parsed_body["data"]
      expect(data["period"]).to eq("30m")
      expect(data).to have_key("points")
      expect(data).to have_key("anomalies")
    end

    it "returns 7d data for premium user with tracked channel" do
      premium_user = create(:user, tier: "premium")
      create(:tracked_channel, user: premium_user, channel: channel, tracking_enabled: true)
      create(:subscription, user: premium_user, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trust/history",
          params: { period: "7d" },
          headers: auth_headers(premium_user)
      expect(response).to have_http_status(:ok)

      data = response.parsed_body["data"]
      expect(data["period"]).to eq("7d")
    end

    it "returns 403 for free user requesting 7d" do
      get "/api/v1/channels/#{channel.id}/trust/history",
          params: { period: "7d" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 400 for invalid period" do
      get "/api/v1/channels/#{channel.id}/trust/history",
          params: { period: "invalid" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end

    it "includes empty anomalies array when no anomalies" do
      get "/api/v1/channels/#{channel.id}/trust/history", headers: auth_headers(user)
      data = response.parsed_body["data"]
      expect(data["anomalies"]).to eq([])
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
