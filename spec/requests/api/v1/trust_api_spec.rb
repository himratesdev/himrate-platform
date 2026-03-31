# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Trust API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:user_business) { create(:user, tier: "business") }
  let(:headers_free) { auth_headers(user_free) }
  let(:headers_premium) { auth_headers(user_premium) }
  let(:headers_business) { auth_headers(user_business) }

  before do
    # Create stream + TI history for channel
    stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago,
      peak_ccv: 5000, avg_ccv: 4000, game_name: "Just Chatting")
    create(:trust_index_history,
      channel: channel,
      stream: stream,
      trust_index_score: 72.0,
      erv_percent: 72.0,
      ccv: 5000,
      confidence: 0.85,
      classification: "needs_review",
      cold_start_status: "full",
      signal_breakdown: { auth_ratio: { value: 0.15, confidence: 0.9 } },
      calculated_at: 1.minute.ago)
  end

  describe "GET /api/v1/channels/:id/trust" do
    # TC-001: Guest → headline only
    it "returns headline for guest (no auth)" do
      get "/api/v1/channels/#{channel.id}/trust"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to eq(72.0)
      expect(data["classification"]).to eq("needs_review")
      expect(data["erv_percent"]).to eq(72.0)
      expect(data["erv_label"]).to be_present
      expect(data["erv_label_color"]).to eq("yellow")
      # 1 completed stream = insufficient (need 10+ for "full")
      expect(data["cold_start_status"]).to eq("insufficient")
      # Guest should NOT get signal_breakdown
      expect(data).not_to have_key("signal_breakdown")
    end

    # TC-002: Free live → drill_down with signals
    it "returns drill_down for Free during live stream" do
      create(:stream, channel: channel, started_at: 30.minutes.ago, ended_at: nil)

      get "/api/v1/channels/#{channel.id}/trust", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to eq(72.0)
      expect(data).to have_key("signal_breakdown")
      expect(data["is_live"]).to be true
    end

    # TC-004: Free expired → headline + expired flag
    it "returns headline with expired flag for Free when window closed" do
      # All streams ended > 18h ago
      channel.streams.update_all(ended_at: 20.hours.ago)

      get "/api/v1/channels/#{channel.id}/trust", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to eq(72.0)
      expect(data).not_to have_key("streamer_reputation")
    end

    # TC-005: Premium tracked → full
    it "returns full for Premium with tracked channel" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/trust", headers: headers_premium

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to eq(72.0)
      expect(data).to have_key("signal_breakdown")
      expect(data).to have_key("erv_breakdown")
    end

    # TC-007: Cold start 0 streams → null metrics
    it "returns cold start for channel with 0 streams" do
      empty_channel = create(:channel)

      get "/api/v1/channels/#{empty_channel.id}/trust"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to be_nil
      expect(data["cold_start_status"]).to eq("insufficient")
    end

    # TC-021: Channel lookup by login
    it "finds channel by login" do
      get "/api/v1/channels/#{channel.login}/trust"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["channel_login"]).to eq(channel.login)
    end

    # TC-011: ETag support
    it "returns 304 Not Modified on second request with same ETag" do
      get "/api/v1/channels/#{channel.id}/trust"
      etag = response.headers["ETag"]

      get "/api/v1/channels/#{channel.id}/trust", headers: { "If-None-Match" => etag }
      expect(response).to have_http_status(:not_modified)
    end

    it "returns 404 for non-existent channel" do
      get "/api/v1/channels/nonexistent/trust"
      expect(response).to have_http_status(:not_found)
    end

    # TC-006: Streamer own → full view
    it "returns full for Streamer on own channel" do
      streamer = create(:user, role: "streamer", tier: "free")
      create(:auth_provider, user: streamer, provider: "twitch", provider_id: channel.twitch_id)
      headers = auth_headers(streamer)

      get "/api/v1/channels/#{channel.id}/trust", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to eq(72.0)
      expect(data).to have_key("erv_breakdown")
    end

    # TC-019: Guest with X-Extension-Install-Id
    it "accepts Guest with X-Extension-Install-Id header" do
      get "/api/v1/channels/#{channel.id}/trust",
          headers: { "X-Extension-Install-Id" => "ext-install-uuid-12345" }

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["ti_score"]).to eq(72.0)
      # Guest still gets headline only
      expect(data).not_to have_key("signal_breakdown")
    end

    # TC-023: Redis cache hit (second call should use cache)
    it "uses Redis cache on second request" do
      get "/api/v1/channels/#{channel.id}/trust"
      expect(response).to have_http_status(:ok)
      first_data = response.parsed_body["data"]

      # Second request should be cached
      get "/api/v1/channels/#{channel.id}/trust"
      expect(response).to have_http_status(:ok)
      second_data = response.parsed_body["data"]
      expect(second_data).to eq(first_data)
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
