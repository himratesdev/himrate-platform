# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Brand::StreamerCards", type: :request do
  let(:brand_user) { create(:user, :brand) }
  let!(:channel) { create(:channel, login: "teststreamer", display_name: "Test Streamer") }

  before do
    create(:stream, channel: channel, game_name: "Dota 2", language: "ru")
    # Explicit in-window dates — the factory's sequence(:date) is a leaky global counter that
    # drifts outside the 30-day window in the full suite.
    3.times { |i| create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date, ccv_avg: 12_400, erv_avg_percent: 72.0, ccv_peak: 18_100, streams_count: 1) }
    create(:trust_index_history, channel: channel, classification: "trusted",
                                 signal_breakdown: {
                                   "auth_ratio" => { "value" => 1.0, "weight" => 0.14, "confidence" => 1.0, "contribution" => 0.14 },
                                   "known_bot_match" => { "value" => 0.0, "weight" => 0.1, "confidence" => 1.0, "contribution" => 0.0 }
                                 })
  end

  it "returns the brand streamer card for a brand user" do
    get "/api/v1/brand/streamers/teststreamer/card", headers: auth_headers(brand_user)

    expect(response).to have_http_status(:ok)
    data = response.parsed_body["data"]
    expect(data["channel"]["login"]).to eq("teststreamer")
    expect(data["channel"]["category"]).to eq("Dota 2")

    expect(data["window"]["streams_count"]).to be > 0 # top-level per SRS §4A / AC-3
    expect(data["window"]["days"]).to eq(30)

    l1 = data["layer1_real_audience"]
    expect(l1["available"]).to be(true)
    expect(l1["shown_avg_viewers"]).to eq(12_400)
    expect(l1["real_avg_viewers"]).to eq(8928) # 12400 * 72%
    expect(l1["real_avg_viewers"]).to be < l1["shown_avg_viewers"] # real bot-correction, not a mock
    expect(l1["bot_correction_pct"]).to be < 0

    l2 = data["layer2_authenticity"]
    expect(l2["available"]).to be(true)
    expect(l2["classification"]).to eq("trusted")
    expect(l2["checks"].map { |c| c["signal"] }).to include("auth_ratio", "known_bot_match")

    expect(data["deferred"]).to include("social_platforms", "layer2_per_signal_verdict")
  end

  it "returns insufficient_window (no mock) for a channel without 30-day data" do
    bare = create(:channel, login: "coldstart")
    get "/api/v1/brand/streamers/coldstart/card", headers: auth_headers(brand_user)

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "layer1_real_audience", "available")).to be(false)
    expect(response.parsed_body.dig("data", "layer1_real_audience", "reason")).to eq("insufficient_window")
  end

  it "resolves login case-insensitively" do
    get "/api/v1/brand/streamers/TestStreamer/card", headers: auth_headers(brand_user)
    expect(response).to have_http_status(:ok)
  end

  it "denies a non-brand user (403)" do
    get "/api/v1/brand/streamers/teststreamer/card", headers: auth_headers(create(:user))
    expect(response).to have_http_status(:forbidden)
  end

  it "returns 404 for an unknown login" do
    get "/api/v1/brand/streamers/ghost/card", headers: auth_headers(brand_user)
    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("CHANNEL_NOT_FOUND")
  end

  it "requires auth" do
    get "/api/v1/brand/streamers/teststreamer/card"
    expect(response).to have_http_status(:unauthorized)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" }
  end
end
