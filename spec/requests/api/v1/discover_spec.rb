# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Discover", type: :request do
  let(:user) { create(:user) }
  let(:headers) { { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id)}" } }

  # V1-RETIRE: v2 rows — native erv count + authenticity (ti = % real), band persisted.
  def live_channel(login:, ccv:, ti:, started_at: 1.hour.ago, band_row: 3, band_color: "green",
                   game: "Dota 2", language: "ru")
    channel = create(:channel, login: login, is_monitored: true)
    create(:stream, channel: channel, started_at: started_at, ended_at: nil, game_name: game, language: language)
    create(:trust_index_history, channel: channel, ccv: ccv, erv: (ccv * ti / 100.0).round,
                                 authenticity: ti.to_f, band_row: band_row, band_color: band_color,
                                 calculated_at: 5.minutes.ago)
    channel
  end

  describe "GET /api/v1/discover/live" do
    # The home page's live board — open BY CODE, not through the open-house demo session (which
    # stays OFF here: HOOK_FLAGS are registered but never enabled).
    it "answers a guest without a session; nothing is marked as watched" do
      expect(Flipper.enabled?(:open_house_guest_access)).to be(false)
      live_channel(login: "public_live", ccv: 100, ti: 90)

      get "/api/v1/discover/live"

      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].sole
      expect(row["login"]).to eq("public_live")
      expect(row["is_watched_by_user"]).to be(false)
    end

    it "returns live channels ranked by REAL audience (native v2 erv), with headline fields" do
      live_channel(login: "big_shown", ccv: 10_000, ti: 40, band_row: 2, band_color: "yellow") # real 4000
      live_channel(login: "real_king", ccv: 6_000, ti: 95)    # real 5700 — must rank first
      # offline channel must not appear
      offline = create(:channel, login: "sleeper", is_monitored: true)
      create(:stream, channel: offline, started_at: 2.days.ago, ended_at: 1.day.ago)

      # V1-RETIRE: erv_label re-derived from band_row via band.<key> under the REQUEST locale
      get "/api/v1/discover/live", headers: headers.merge("Accept-Language" => "ru")
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.map { |c| c["login"] }).to eq(%w[real_king big_shown])
      top = data.first
      expect(top["real_viewers"]).to eq(5700)
      expect(top["shown_viewers"]).to eq(6000)
      expect(top["erv_percent"]).to eq(95.0) # authenticity under the legacy wire name
      expect(top["erv_label"]).to eq("Аудитория реальная") # band_row 3 → band.green_real (ru)
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

    # Live 2026-09-19: `?game=Dota 2&limit=50` answered 50 rows across 18 games — only `limit` was read.
    it "applies the category filter from the query string" do
      live_channel(login: "dota_one", ccv: 100, ti: 90, game: "Dota 2")
      live_channel(login: "cs_one", ccv: 900, ti: 90, game: "Counter-Strike 2")

      get "/api/v1/discover/live", params: { game: "Dota 2", limit: 50 }

      expect(response.parsed_body["data"].map { |c| c["login"] }).to eq(%w[dota_one])
    end

    it "wires every filter param through to the query" do
      live_channel(login: "match", ccv: 2000, ti: 50, band_row: 2, band_color: "yellow", language: "en")
      live_channel(login: "wrong_lang", ccv: 2000, ti: 50, band_row: 2, band_color: "yellow", language: "ru")
      live_channel(login: "wrong_band", ccv: 2000, ti: 50, language: "en")
      live_channel(login: "too_small", ccv: 100, ti: 50, band_row: 2, band_color: "yellow", language: "en")

      get "/api/v1/discover/live",
          params: { game: "dota 2", language: "EN", band: "yellow", min_viewers: 500, max_viewers: 1500 }

      expect(response.parsed_body["data"].map { |c| c["login"] }).to eq(%w[match])
    end
  end
end
