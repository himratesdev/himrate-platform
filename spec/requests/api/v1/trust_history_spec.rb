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

    # TASK-085 FR-023: build_anomalies fix — broken Anomaly.where(channel_id:, detected_at:)
    # replaced with correct JOIN streams + timestamp column. Pre-fix wrapped в silent rescue (dead code).
    it "build_anomalies returns valid anomaly records via stream JOIN (FR-023)" do
      stream = create(:stream, channel: channel, started_at: 10.minutes.ago)
      create(:anomaly, stream: stream, anomaly_type: "ti_drop", timestamp: 5.minutes.ago,
        confidence: 0.95, details: { "delta_pts" => 18 })
      create(:anomaly, stream: stream, anomaly_type: "anomaly_wave", timestamp: 2.minutes.ago,
        confidence: 1.0, details: { "signal_value" => 0.85 })

      get "/api/v1/channels/#{channel.id}/trust/history", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)

      anomalies = response.parsed_body["data"]["anomalies"]
      expect(anomalies.size).to eq(2)
      expect(anomalies.map { |a| a["type"] }).to contain_exactly("ti_drop", "anomaly_wave")
      # New shape: timestamp + confidence + details (replaces broken severity/delta_value)
      expect(anomalies.first).to include("timestamp", "type", "confidence", "details")
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
