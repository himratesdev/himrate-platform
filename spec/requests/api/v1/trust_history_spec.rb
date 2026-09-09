# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trust History API" do
  let(:channel) { create(:channel) }
  let(:user) { create(:user) }

  describe "GET /api/v1/channels/:id/trust/history" do
    # WEB-CONSOLIDATION §7 block 4 (2026-09-09): how the online moved during THIS broadcast is a
    # fact about the channel, so the 30m series is open to a guest too. The 7-day depth stays paid
    # (view_7d_trust_history?, covered below). Was: 403 SUBSCRIPTION_REQUIRED for a guest.
    it "returns the 30m series for a guest (no auth)" do
      get "/api/v1/channels/#{channel.id}/trust/history"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "period")).to eq("30m")
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

    # T1-060 FR-6: 7d gate now flows through Pundit (view_7d_trust_history?) + resolve_error_code.
    it "returns 403 EXTENSION_DEEP_LOCKED for a free user requesting 7d on the extension" do
      get "/api/v1/channels/#{channel.id}/trust/history",
          params: { period: "7d" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("EXTENSION_DEEP_LOCKED")
    end

    it "returns 403 SUBSCRIPTION_REQUIRED for a free user requesting 7d on the dashboard surface" do
      get "/api/v1/channels/#{channel.id}/trust/history",
          params: { period: "7d" },
          headers: { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id, surface: 'dashboard')}" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("SUBSCRIPTION_REQUIRED")
    end

    # T1-075: the v2 branch emitted per-point `erv` while the sparkline contract (extension
    # SparklinePoint) reads `erv_count` — no consumer saw the count, charts stayed empty. v2 30m
    # points must carry erv_count = the engine's native V−F̂ count (NOT the retired ccv×ti/100).
    describe "v2 point shape (T1-075)" do
      before do
        allow(Flipper).to receive(:enabled?).and_call_original
        allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
      end

      it "30m points carry erv_count (native count) + authenticity + band_color" do
        stream = create(:stream, channel: channel, started_at: 20.minutes.ago, ended_at: nil)
        create(:ccv_snapshot, stream: stream, timestamp: 5.minutes.ago, ccv_count: 1000)
        create(:trust_index_history, :v2, channel: channel, stream: stream,
          erv: 553.4, authenticity: 55.3, band_color: "yellow", calculated_at: 6.minutes.ago)

        get "/api/v1/channels/#{channel.id}/trust/history", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)

        point = response.parsed_body["data"]["points"].first
        expect(point["erv_count"]).to eq(553)
        expect(point["ccv"]).to eq(1000)
        expect(point["authenticity"]).to eq(55.3)
        expect(point["band_color"]).to eq("yellow")
        expect(point).not_to have_key("erv")
      end

      it "7d aggregate points carry the erv_count key (nil) + authenticity" do
        premium_user = create(:user, tier: "premium")
        create(:tracked_channel, user: premium_user, channel: channel, tracking_enabled: true)
        create(:subscription, user: premium_user, tier: "premium", is_active: true)
        create(:trust_index_history, :v2, channel: channel, authenticity: 82.0,
          calculated_at: 1.day.ago)

        get "/api/v1/channels/#{channel.id}/trust/history",
            params: { period: "7d" }, headers: auth_headers(premium_user)
        expect(response).to have_http_status(:ok)

        point = response.parsed_body["data"]["points"].first
        expect(point).to have_key("erv_count")
        expect(point["erv_count"]).to be_nil
        expect(point["authenticity"]).to eq(82.0)
      end
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
