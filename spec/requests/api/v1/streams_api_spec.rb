# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Streams API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers_free) { auth_headers(user_free) }
  let(:headers_premium) { auth_headers(user_premium) }

  before do
    # Create completed streams with TI data
    3.times do |i|
      stream = create(:stream, channel: channel,
        started_at: (i + 1).days.ago,
        ended_at: (i + 1).days.ago + 3.hours,
        peak_ccv: 5000 - (i * 500),
        avg_ccv: 4000 - (i * 400),
        game_name: "Just Chatting")

      create(:trust_index_history,
        channel: channel, stream: stream,
        trust_index_score: 75.0 - (i * 5),
        erv_percent: 75.0 - (i * 5),
        ccv: stream.peak_ccv,
        classification: "needs_review",
        cold_start_status: "full",
        calculated_at: stream.ended_at)
    end
  end

  describe "GET /api/v1/channels/:id/streams" do
    # TC-009: Free → 403
    it "returns 403 for Free user" do
      get "/api/v1/channels/#{channel.id}/streams", headers: headers_free
      expect(response).to have_http_status(:forbidden)
    end

    # TC-008: Premium tracked → paginated list
    it "returns paginated streams for Premium with tracked channel" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)

      get "/api/v1/channels/#{channel.id}/streams", headers: headers_premium

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["data"].size).to eq(3)
      expect(body["meta"]["total"]).to eq(3)

      first_stream = body["data"].first
      expect(first_stream).to have_key("ti_score")
      expect(first_stream).to have_key("erv_percent")
      expect(first_stream).to have_key("peak_ccv")
    end

    # TC-010: Streamer own → 200
    it "returns streams for Streamer on own channel" do
      streamer = create(:user, role: "streamer", tier: "free")
      create(:auth_provider, user: streamer, provider: "twitch", provider_id: channel.twitch_id)
      headers = auth_headers(streamer)

      get "/api/v1/channels/#{channel.id}/streams", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(3)
    end

    it "returns 401 without auth" do
      get "/api/v1/channels/#{channel.id}/streams"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/channels/:id/streams/:stream_id/report" do
    let(:stream) { channel.streams.order(started_at: :desc).first }

    # TC-012: Free expired → 403
    it "returns 403 for Free when window expired" do
      channel.streams.update_all(ended_at: 20.hours.ago)

      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}/report", headers: headers_free
      expect(response).to have_http_status(:forbidden)
    end

    # TC-011: Free in window → full report
    it "returns report for Free when window open" do
      stream.update!(ended_at: 2.hours.ago)

      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}/report", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to have_key("stream")
      expect(data).to have_key("trust_index")
      expect(data).to have_key("ccv_timeline")
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
