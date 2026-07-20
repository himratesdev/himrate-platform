# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Discover", type: :request do
  let(:user) { create(:user) }
  let(:headers) { { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" } }

  def live_channel(login:, ccv:, ti:, started_at: 1.hour.ago)
    channel = create(:channel, login: login, is_monitored: true)
    create(:stream, channel: channel, started_at: started_at, ended_at: nil, game_name: "Dota 2")
    create(:trust_index_history, channel: channel, ccv: ccv, erv_percent: ti, trust_index_score: ti, calculated_at: 5.minutes.ago)
    channel
  end

  describe "GET /api/v1/discover/live" do
    it "requires auth" do
      get "/api/v1/discover/live"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns live channels ranked by REAL audience (ccv × erv%), with headline fields" do
      live_channel(login: "big_shown", ccv: 10_000, ti: 40)   # real 4000
      live_channel(login: "real_king", ccv: 6_000, ti: 95)    # real 5700 — must rank first
      # offline channel must not appear
      offline = create(:channel, login: "sleeper", is_monitored: true)
      create(:stream, channel: offline, started_at: 2.days.ago, ended_at: 1.day.ago)

      get "/api/v1/discover/live", headers: headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.map { |c| c["login"] }).to eq(%w[real_king big_shown])
      top = data.first
      expect(top["real_viewers"]).to eq(5700)
      expect(top["shown_viewers"]).to eq(6000)
      expect(top["erv_label"]).to eq("Аудитория реальная")
      expect(top["erv_label_color"]).to eq("green")
      expect(top["game_name"]).to eq("Dota 2")
      expect(top["started_at"]).to be_present
    end

    it "marks channels the user already watches (is_watched_by_user)" do
      channel = live_channel(login: "tracked_one", ccv: 100, ti: 90)
      create(:tracked_channel, user: user, channel: channel, tracking_enabled: true)

      get "/api/v1/discover/live", headers: headers
      expect(response.parsed_body["data"].first["is_watched_by_user"]).to be(true)
    end

    it "deduplicates stale unclosed streams (one card per channel)" do
      channel = live_channel(login: "double_live", ccv: 100, ti: 90)
      create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)

      get "/api/v1/discover/live", headers: headers
      logins = response.parsed_body["data"].map { |c| c["login"] }
      expect(logins.count("double_live")).to eq(1)
    end

    it "excludes ghost never-closed rows older than the recency bound (scale guard)" do
      live_channel(login: "ghost_ch", ccv: 100, ti: 90, started_at: 3.days.ago)
      live_channel(login: "fresh_ch", ccv: 100, ti: 90)

      get "/api/v1/discover/live", headers: headers
      expect(response.parsed_body["data"].map { |c| c["login"] }).to eq(%w[fresh_ch])
    end

    it "returns [] when nothing is live (honest empty, no samples)" do
      get "/api/v1/discover/live", headers: headers
      expect(response.parsed_body["data"]).to eq([])
    end
  end
end
