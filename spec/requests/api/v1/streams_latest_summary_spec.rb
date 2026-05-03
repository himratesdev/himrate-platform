# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Streams Latest Summary API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers_free) { auth_headers(user_free) }
  let(:headers_premium) { auth_headers(user_premium) }

  describe "GET /api/v1/channels/:id/streams/latest/summary" do
    # FR-003 / US-013: Guest → 401
    it "returns 401 для guest (no auth)" do
      create(:stream, channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago,
        duration_ms: 18_000_000, peak_ccv: 5000)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary"

      expect(response).to have_http_status(:unauthorized)
    end

    # FR-002 / US-001 alt: Free + expired window → 403 SUBSCRIPTION_REQUIRED
    it "returns 403 для Free вне 18h window" do
      create(:stream, channel: channel, started_at: 25.hours.ago, ended_at: 20.hours.ago,
        duration_ms: 18_000_000, peak_ccv: 5000)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary", headers: headers_free

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("SUBSCRIPTION_REQUIRED")
    end

    # FR-001 / US-001: Free в 18h окне → 200 с full data
    it "returns 200 full data для Free в 18h post-stream window" do
      stream = create(:stream, channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago,
        duration_ms: 18_000_000, peak_ccv: 5000, avg_ccv: 3500, game_name: "Just Chatting")
      create(:post_stream_report, stream: stream, ccv_peak: 5234, ccv_avg: 3650,
        erv_percent_final: 85.5, erv_final: 4200, duration_ms: 18_000_000)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["session_id"]).to eq(stream.id)
      expect(data["peak_viewers"]).to eq(5234)
      expect(data["erv_percent_final"]).to be_within(0.1).of(85.5)
      expect(data["erv_count_final"]).to eq(4200)
      expect(data["category"]).to eq("Just Chatting")
      expect(data["partial"]).to be(false)
      expect(response.parsed_body["meta"]["preliminary"]).to be(false)
    end

    # FR-004 / EC-1: No completed streams → 404
    it "returns 404 STREAM_NOT_FOUND когда канал не имеет completed streams" do
      get "/api/v1/channels/#{channel.id}/streams/latest/summary", headers: headers_free

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("STREAM_NOT_FOUND")
    end

    # US-002: Premium tracked → no time restriction
    it "returns 200 для Premium tracked канал без time restriction" do
      create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
      create(:subscription, user: user_premium, tier: "premium", is_active: true)
      stream = create(:stream, channel: channel, started_at: 100.hours.ago, ended_at: 95.hours.ago,
        duration_ms: 18_000_000, peak_ccv: 5000, game_name: "Gaming")
      create(:post_stream_report, stream: stream, ccv_peak: 5000, generated_at: 90.hours.ago)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary", headers: headers_premium

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["session_id"]).to eq(stream.id)
    end

    # FR-007: duration_text per Accept-Language
    it "formats duration_text per Accept-Language RU" do
      stream = create(:stream, channel: channel, started_at: 7.hours.ago, ended_at: 1.hour.ago,
        duration_ms: 22_320_000, peak_ccv: 5000)
      create(:post_stream_report, stream: stream)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary",
        headers: headers_free.merge("Accept-Language" => "ru")

      expect(response.parsed_body["data"]["duration_text"]).to eq("6ч 12м")
    end

    it "formats duration_text per Accept-Language EN" do
      stream = create(:stream, channel: channel, started_at: 7.hours.ago, ended_at: 1.hour.ago,
        duration_ms: 22_320_000, peak_ccv: 5000)
      create(:post_stream_report, stream: stream)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary",
        headers: headers_free.merge("Accept-Language" => "en")

      expect(response.parsed_body["data"]["duration_text"]).to eq("6h 12m")
    end

    # FR-006 / EC-5: meta.preliminary = true когда post_stream_reports nil
    it "returns preliminary state когда PostStreamReport не существует" do
      create(:stream, channel: channel, started_at: 6.hours.ago, ended_at: 1.hour.ago,
        duration_ms: 18_000_000, peak_ccv: 5000, avg_ccv: 3500)

      get "/api/v1/channels/#{channel.id}/streams/latest/summary", headers: headers_free

      data = response.parsed_body["data"]
      expect(data["peak_viewers"]).to eq(5000)
      expect(data["erv_percent_final"]).to be_nil
      expect(data["erv_count_final"]).to be_nil
      expect(response.parsed_body["meta"]["preliminary"]).to be(true)
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
