# frozen_string_literal: true

require "rails_helper"

# T2-020 StreamBreakdown INC-1: per-stream «Разбор эфира» endpoint. Free layer-2 for registered
# viewers (access-model v2) — no paywall; gated only by registered + live/18h-window (view_breakdown?).
RSpec.describe "Stream Breakdown API", type: :request do
  let(:channel) { create(:channel) }
  let(:user) { create(:user, tier: "free") }
  let(:headers) { auth_headers(user) }

  describe "GET /api/v1/channels/:id/streams/:stream_id/breakdown" do
    it "returns 401 for a guest (unauthenticated)" do
      stream = create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil)
      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}/breakdown"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 200 + the breakdown payload for a registered viewer on a live stream (zero paywall)" do
      stream = create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil, game_name: "Just Chatting")
      create(:ccv_snapshot, stream: stream, ccv_count: 5000, real_viewers_estimate: 1500)
      create(:trust_index_history, channel: channel, stream: stream,
        trust_index_score: 30.0, erv_percent: 30.0, ccv: 5000,
        classification: "needs_review", cold_start_status: "full", calculated_at: Time.current)

      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}/breakdown", headers: headers

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.keys).to include("stream", "verdict", "timeline", "funnel", "auth_series", "anomalies")
      expect(data["verdict"]["ti_score"]).to eq(30.0)
    end

    it "returns 403 for a registered viewer on an offline stream past the 18h window (no paywall, data time-gate)" do
      stream = create(:stream, channel: channel, started_at: 3.days.ago, ended_at: 3.days.ago + 2.hours)
      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}/breakdown", headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
