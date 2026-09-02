# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::WatchlistChannels", type: :request do
  let(:user) { create(:user) }
  let(:auth_headers) { make_auth_headers(user) }

  def make_auth_headers(u)
    token = Auth::JwtService.encode_access(u.id)
    { "Authorization" => "Bearer #{token}" }
  end
  let!(:watchlist) { create(:watchlist, user: user, name: "Test") }
  let!(:channel) { create(:channel) }

  describe "GET /api/v1/watchlists/:id/channels" do
    # Legacy v1 payload (erv_percent / ti_score / erv_label_color / last_ti_at). :ti_v2_engine is
    # in ALL_FLAGS, so rails_helper enables it per example — the v1 stance has to be explicit.
    # The v2 payload of the same endpoint (erv count + authenticity + band_row/label_key/
    # band_color + last_calculated_at) has its own example below.
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(false)
    end

    it "returns enriched channels" do
      create(:watchlist_channel, watchlist: watchlist, channel: channel)

      get "/api/v1/watchlists/#{watchlist.id}/channels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.size).to eq(1)
      expect(data.first["login"]).to eq(channel.login)
      expect(data.first).to have_key("erv_percent")
      expect(data.first).to have_key("ti_score")
      expect(data.first).to have_key("is_live")
      expect(data.first).to have_key("inactive")
      expect(data.first).to have_key("tags")
    end

    it "returns the v2 contract (erv count + authenticity + band) under the cutover flag" do
      # PR3b: T2 reads erv/authenticity/band_row/label_key/band_color — the v1 keys are retired,
      # and a reader still asking for erv_percent must get nothing rather than a stale field.
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
      create(:watchlist_channel, watchlist: watchlist, channel: channel)
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
      TrustIndexHistory.create!(channel: channel, stream: stream, engine_version: "v2",
                                erv: 1200, authenticity: 87.4, band_row: 3, band_color: "green",
                                cold_start_tier: "full", calculated_at: 30.minutes.ago)

      get "/api/v1/watchlists/#{watchlist.id}/channels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      row = response.parsed_body["data"].first
      expect(row["erv"]).to eq(1200)
      expect(row["authenticity"]).to eq(87.4)
      expect(row["band_row"]).to eq(3)
      expect(row["band_color"]).to eq("green")
      expect(row["label_key"]).to be_present
      expect(row).to have_key("last_calculated_at")
      expect(row).not_to have_key("erv_percent")
      expect(row).not_to have_key("ti_score")
    end

    it "returns empty for empty watchlist" do
      get "/api/v1/watchlists/#{watchlist.id}/channels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq([])
    end
  end

  # T1-060 FR-6 (E8): the Watchlists filters paywall (filter_channels?) is surface-aware.
  # `user` is a free owner (no active subscription) → denied; the error CODE differs by surface.
  describe "GET /api/v1/watchlists/:id/channels with filters (E8 paywall)" do
    it "returns EXTENSION_DEEP_LOCKED for a free owner on the extension surface" do
      get "/api/v1/watchlists/#{watchlist.id}/channels", params: { erv_min: 50 }, headers: auth_headers
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("EXTENSION_DEEP_LOCKED")
    end

    it "returns SUBSCRIPTION_REQUIRED for a free owner on the dashboard surface" do
      dashboard = { "Authorization" => "Bearer #{Auth::JwtService.encode_access(user.id, surface: 'dashboard')}" }
      get "/api/v1/watchlists/#{watchlist.id}/channels", params: { erv_min: 50 }, headers: dashboard
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body.dig("error", "code")).to eq("SUBSCRIPTION_REQUIRED")
    end
  end

  describe "POST /api/v1/watchlists/:id/channels" do
    it "adds channel to watchlist" do
      post "/api/v1/watchlists/#{watchlist.id}/channels",
        params: { channel_id: channel.id },
        headers: auth_headers
      expect(response).to have_http_status(:created)
      expect(watchlist.watchlist_channels.count).to eq(1)
    end

    it "adds by login" do
      post "/api/v1/watchlists/#{watchlist.id}/channels",
        params: { channel_login: channel.login },
        headers: auth_headers
      expect(response).to have_http_status(:created)
    end

    it "rejects duplicate" do
      create(:watchlist_channel, watchlist: watchlist, channel: channel)
      post "/api/v1/watchlists/#{watchlist.id}/channels",
        params: { channel_id: channel.id },
        headers: auth_headers
      expect(response).to have_http_status(:conflict)
    end

    it "rejects when full (100)" do
      100.times { create(:watchlist_channel, watchlist: watchlist, channel: create(:channel)) }
      post "/api/v1/watchlists/#{watchlist.id}/channels",
        params: { channel_id: create(:channel).id },
        headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("LIMIT_REACHED")
    end
  end

  describe "DELETE /api/v1/watchlists/:id/channels/:channel_id" do
    it "removes channel from watchlist" do
      create(:watchlist_channel, watchlist: watchlist, channel: channel)
      delete "/api/v1/watchlists/#{watchlist.id}/channels/#{channel.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(watchlist.watchlist_channels.count).to eq(0)
    end
  end

  describe "PATCH /api/v1/watchlists/:id/channels/:channel_id/move" do
    let!(:target) { create(:watchlist, user: user, name: "Target") }

    it "moves channel to another watchlist" do
      create(:watchlist_channel, watchlist: watchlist, channel: channel)
      patch "/api/v1/watchlists/#{watchlist.id}/channels/#{channel.id}/move",
        params: { target_watchlist_id: target.id },
        headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(watchlist.watchlist_channels.count).to eq(0)
      expect(target.watchlist_channels.count).to eq(1)
    end

    it "rejects move to same list" do
      create(:watchlist_channel, watchlist: watchlist, channel: channel)
      patch "/api/v1/watchlists/#{watchlist.id}/channels/#{channel.id}/move",
        params: { target_watchlist_id: watchlist.id },
        headers: auth_headers
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "PATCH /api/v1/watchlists/:id/channels/:channel_id/meta" do
    it "sets tags and notes" do
      create(:watchlist_channel, watchlist: watchlist, channel: channel)
      patch "/api/v1/watchlists/#{watchlist.id}/channels/#{channel.id}/meta",
        params: { tags: %w[fps partner], notes: "Good candidate" },
        headers: auth_headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["tags"]).to eq(%w[fps partner])
      expect(data["notes"]).to eq("Good candidate")
    end
  end
end
