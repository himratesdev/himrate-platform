# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Streams API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers_free) { auth_headers(user_free) }
  let(:headers_premium) { auth_headers(user_premium) }

  before do
    # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv columns dropped — explicit
    # PSR carries the stats. Create completed streams + their PSR rows + TIH.
    3.times do |i|
      stream = create(:stream, channel: channel,
        started_at: (i + 1).days.ago,
        ended_at: (i + 1).days.ago + 3.hours,
        game_name: "Just Chatting")

      create(:post_stream_report, stream: stream,
        ccv_peak: 5000 - (i * 500),
        ccv_avg: 4000 - (i * 400),
        duration_ms: 3 * 3_600_000,
        generated_at: stream.ended_at)

      # V1-RETIRE: rows carry the v2 verdict (authenticity/erv/band), no v1 scalars.
      create(:trust_index_history,
        channel: channel, stream: stream,
        authenticity: 75.0 - (i * 5),
        erv: 3000 - (i * 300),
        ccv: stream.current_peak_ccv, # PR-A1: derived (PSR.ccv_peak)
        calculated_at: stream.ended_at)
    end
  end

  describe "GET /api/v1/channels/:id/streams" do
    # WEB-CONSOLIDATION §7 block 5 / §8 (2026-09-09): a channel's broadcasts and the report
    # for one of them are facts about the channel — open to everyone. The paid depth is the
    # period aggregate and the trends endpoints, both untouched.
    it "returns the list to a Free user" do
      get "/api/v1/channels/#{channel.id}/streams", headers: headers_free
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to be_an(Array)
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

      # V1-RETIRE: stream_summary merges the v2 verdict block.
      first_stream = body["data"].first
      expect(first_stream["erv"]).to eq(3000)
      expect(first_stream["authenticity"]).to eq(75.0)
      expect(first_stream["band_row"]).to eq(4)
      expect(first_stream["label_key"]).to eq("band.green_no_anomaly")
      expect(first_stream["band_color"]).to eq("green")
      expect(first_stream["engine_version"]).to eq("v2")
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

    it "answers a guest with no auth at all" do
      get "/api/v1/channels/#{channel.id}/streams"
      expect(response).to have_http_status(:ok)
      # Each row carries the verdict wording resolved server-side.
      expect(response.parsed_body["data"].first).to have_key("label")
    end
  end

  describe "GET /api/v1/channels/:id/streams/:stream_id/report" do
    let(:stream) { channel.streams.order(started_at: :desc).first }

    it "returns the report to a Free user long after the broadcast ended" do
      channel.streams.update_all(ended_at: 20.hours.ago)

      get "/api/v1/channels/#{channel.id}/streams/#{stream.id}/report", headers: headers_free
      expect(response).to have_http_status(:ok)
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
