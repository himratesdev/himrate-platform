# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Me::Home", type: :request do
  let(:user) { create(:user) }

  describe "POST /api/v1/me/home/recent_channels" do
    it "tracks an opened channel by login (case-insensitive)" do
      create(:channel, login: "buster")

      expect do
        post "/api/v1/me/home/recent_channels", params: { login: "Buster" }, headers: auth_headers(user)
      end.to change(RecentChannel, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["tracked"]).to be(true)
    end

    it "returns 404 for an unknown login" do
      post "/api/v1/me/home/recent_channels", params: { login: "ghost" }, headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.dig("error", "code")).to eq("CHANNEL_NOT_FOUND")
    end

    it "requires auth" do
      post "/api/v1/me/home/recent_channels", params: { login: "buster" }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/v1/me/home/recent_channels" do
    it "returns the viewer's recent channels, newest first" do
      old = create(:channel, login: "oldc")
      fresh = create(:channel, login: "newc")
      create(:recent_channel, user: user, channel: old, opened_at: 2.hours.ago)
      create(:recent_channel, user: user, channel: fresh, opened_at: 1.minute.ago)

      get "/api/v1/me/home/recent_channels", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |c| c["login"] }).to eq(%w[newc oldc])
    end
  end

  describe "GET /api/v1/me/home/live_channels" do
    it "returns only live channels from the viewer's watchlists" do
      wl = create(:watchlist, user: user)
      live = create(:channel, login: "live_one")
      offline = create(:channel, login: "off_one")
      create(:watchlist_channel, watchlist: wl, channel: live)
      create(:watchlist_channel, watchlist: wl, channel: offline)
      create(:stream, channel: live, ended_at: nil)
      create(:stream, channel: offline) # factory default = ended

      get "/api/v1/me/home/live_channels", params: { source: "watchlists" }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |c| c["login"] }).to eq([ "live_one" ])
    end

    it "returns 501 for an unsupported source" do
      get "/api/v1/me/home/live_channels", params: { source: "subscriptions" }, headers: auth_headers(user)
      expect(response).to have_http_status(:not_implemented)
    end
  end

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
