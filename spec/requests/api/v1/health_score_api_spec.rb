# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Health Score API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers_free) { auth_headers(user_free) }
  let(:headers_premium) { auth_headers(user_premium) }

  before do
    # TASK-038: seed DB-driven config
    load Rails.root.join("db/seeds/health_score.rb") unless HealthScoreCategory.exists?
    HealthScoreSeeds.run

    create(:health_score,
      channel: channel,
      health_score: 72.5,
      ti_component: 75.0,
      stability_component: 80.0,
      engagement_component: 65.0,
      growth_component: 70.0,
      consistency_component: 68.0,
      confidence_level: "full",
      calculated_at: 1.hour.ago)

    # Need 10+ completed streams for "full" cold start
    10.times do |i|
      create(:stream, channel: channel,
        started_at: (i + 1).days.ago,
        ended_at: (i + 1).days.ago + 3.hours)
    end
  end

  describe "GET /api/v1/channels/:id/health_score" do
    # TC-014: Guest → 401, Free → 403
    it "returns 401 for unauthenticated" do
      get "/api/v1/channels/#{channel.id}/health_score"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 for Free user" do
      get "/api/v1/channels/#{channel.id}/health_score", headers: headers_free
      expect(response).to have_http_status(:forbidden)
    end

    # TC-013: Streamer own → HS + badge
    it "returns HS for Streamer on own channel" do
      streamer = create(:user, role: "streamer", tier: "free")
      create(:auth_provider, user: streamer, provider: "twitch", provider_id: channel.twitch_id)
      headers = auth_headers(streamer)

      get "/api/v1/channels/#{channel.id}/health_score", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["health_score"]).to eq(72.5)
      expect(data["label"]).to be_present
      expect(data["components"]["ti"]).to eq(75.0)
      expect(data["components"]["stability"]).to eq(80.0)
      expect(data["stream_count"]).to eq(10)
      expect(data["cold_start_tier"]).to eq("full")
    end

    # TC-015: Premium tracked → HS + 30d trend
    it "returns HS with 30d trend for Premium with tracked channel" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/health_score", headers: headers_premium

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["health_score"]).to eq(72.5)
      expect(data).to have_key("trend_30d")
      expect(data).not_to have_key("trend_60d")
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
