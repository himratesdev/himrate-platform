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

    it "returns empty for empty watchlist" do
      get "/api/v1/watchlists/#{watchlist.id}/channels", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq([])
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
