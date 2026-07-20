# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Me::Moments", type: :request do
  let(:user) { create(:user) }
  let(:headers) { { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" } }
  let(:channel) { create(:channel, login: "momchan") }

  def minute(ts, count)
    { msg_count: count, timestamp: ts }
  end

  describe "GET /api/v1/me/moments" do
    it "requires auth" do
      get "/api/v1/me/moments", params: { login: "momchan" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "404s an unknown channel" do
      get "/api/v1/me/moments", params: { login: "ghost" }, headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "returns honest-empty when the channel has no finished streams" do
      channel
      get "/api/v1/me/moments", params: { login: "momchan" }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "moments")).to eq([])
      expect(response.parsed_body.dig("data", "clips", "status")).to eq("none")
    end

    it "detects chat-peak windows (≥2× median, merged adjacent, ranked) + enqueues the clips fetch" do
      stream = create(:stream, channel: channel, started_at: Time.utc(2026, 7, 20, 18, 0), ended_at: Time.utc(2026, 7, 20, 20, 0))
      base = stream.started_at
      histogram = (0..59).map { |i| minute(base + i.minutes, 10) } # baseline median 10
      histogram[20][:msg_count] = 45  # spike ×4.5
      histogram[21][:msg_count] = 38  # adjacent — merges into one window
      histogram[40][:msg_count] = 25  # spike ×2.5
      allow(Clickhouse::ChatQueries).to receive(:chat_rate).with(stream, stream.started_at).and_return(histogram)

      expect(Moments::ClipsFetchWorker).to receive(:perform_async).with(stream.id)
      get "/api/v1/me/moments", params: { login: "momchan" }, headers: headers

      expect(response).to have_http_status(:ok)
      moments = response.parsed_body.dig("data", "moments")
      expect(moments.size).to eq(2)
      first = moments.find { |m| m["offset_sec"] == 20 * 60 }
      expect(first["multiplier"]).to eq(4.5)
      expect(first["duration_sec"]).to eq(120) # two merged minutes
      expect(first["type"]).to eq("chat_peak")
      expect(moments.map { |m| m["offset_sec"] }).to eq([ 1200, 2400 ]) # chronological
      expect(response.parsed_body.dig("data", "clips", "status")).to eq("pending")
      expect(response.parsed_body.dig("data", "stream", "id")).to eq(stream.id)
    end

    it "returns [] moments when chat history is empty (honest, no samples)" do
      stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago)
      allow(Clickhouse::ChatQueries).to receive(:chat_rate).and_return([])

      get "/api/v1/me/moments", params: { login: "momchan" }, headers: headers
      expect(response.parsed_body.dig("data", "moments")).to eq([])
      expect(response.parsed_body.dig("data", "stream", "id")).to eq(stream.id)
    end

    it "serves cached clips with moment matching by vod_offset (±90s window)" do
      stream = create(:stream, channel: channel, started_at: Time.utc(2026, 7, 20, 18, 0), ended_at: Time.utc(2026, 7, 20, 20, 0))
      base = stream.started_at
      histogram = (0..59).map { |i| minute(base + i.minutes, 10) }
      histogram[20][:msg_count] = 45
      allow(Clickhouse::ChatQueries).to receive(:chat_rate).and_return(histogram)
      Rails.cache.write(Moments::ClipsFetchWorker.cache_key(stream.id), [
        { "id" => "ClipNear", "title" => "clutch", "vod_offset" => 20 * 60 + 30, "view_count" => 100 },
        { "id" => "ClipFar", "title" => "unrelated", "vod_offset" => 50 * 60, "view_count" => 5 }
      ])

      get "/api/v1/me/moments", params: { login: "momchan" }, headers: headers
      clips = response.parsed_body.dig("data", "clips")
      expect(clips["status"]).to eq("ready")
      near = clips["items"].find { |c| c["id"] == "ClipNear" }
      far = clips["items"].find { |c| c["id"] == "ClipFar" }
      expect(near["moment_offset_sec"]).to eq(1200)
      expect(far["moment_offset_sec"]).to be_nil
    end

    it "selects a specific stream via stream_id and lists the selector streams" do
      old = create(:stream, channel: channel, started_at: 3.days.ago, ended_at: 3.days.ago + 2.hours)
      create(:stream, channel: channel, started_at: 1.day.ago, ended_at: 1.day.ago + 2.hours)
      allow(Clickhouse::ChatQueries).to receive(:chat_rate).and_return([])

      get "/api/v1/me/moments", params: { login: "momchan", stream_id: old.id }, headers: headers
      expect(response.parsed_body.dig("data", "stream", "id")).to eq(old.id)
      expect(response.parsed_body.dig("data", "streams").size).to eq(2)
    end
  end
end
