# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Watchlists", type: :request do
  let(:user) { create(:user) }
  let(:auth_headers) { jwt_auth_headers(user) }

  def jwt_auth_headers(u)
    token = Auth::JwtService.encode_access(u.id)
    { "Authorization" => "Bearer #{token}" }
  end

  describe "GET /api/v1/watchlists" do
    it "returns empty list with default watchlist auto-created" do
      get "/api/v1/watchlists", headers: auth_headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data.size).to eq(1)
      expect(data.first["name"]).to eq("My Watchlist")
    end

    it "returns watchlists with stats" do
      wl = create(:watchlist, user: user, name: "Test", position: 0)
      channel = create(:channel)
      create(:watchlist_channel, watchlist: wl, channel: channel)

      get "/api/v1/watchlists", headers: auth_headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      test_wl = data.find { |w| w["name"] == "Test" }
      expect(test_wl["channels_count"]).to eq(1)
      expect(test_wl["stats"]["total"]).to eq(1)
    end

    it "returns 401 for unauthenticated" do
      get "/api/v1/watchlists"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /api/v1/watchlists" do
    it "creates a new watchlist" do
      post "/api/v1/watchlists",
        params: { watchlist: { name: "New List" } },
        headers: auth_headers
      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["name"]).to eq("New List")
      expect(user.watchlists.count).to eq(1)
    end

    it "rejects empty name" do
      post "/api/v1/watchlists",
        params: { watchlist: { name: "" } },
        headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /api/v1/watchlists/:id" do
    let!(:watchlist) { create(:watchlist, user: user, name: "Old Name") }

    it "renames watchlist" do
      patch "/api/v1/watchlists/#{watchlist.id}",
        params: { watchlist: { name: "New Name" } },
        headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["name"]).to eq("New Name")
    end

    it "rejects other user's watchlist" do
      other = create(:user)
      other_wl = create(:watchlist, user: other)
      patch "/api/v1/watchlists/#{other_wl.id}",
        params: { watchlist: { name: "Hack" } },
        headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/v1/watchlists/:id" do
    it "deletes watchlist and auto-creates default" do
      wl = create(:watchlist, user: user, name: "Only One")
      delete "/api/v1/watchlists/#{wl.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(user.watchlists.reload.count).to eq(1)
      expect(user.watchlists.first.name).to eq("My Watchlist")
    end

    it "deletes without auto-create when others exist" do
      create(:watchlist, user: user, name: "Keep")
      wl = create(:watchlist, user: user, name: "Delete Me")
      delete "/api/v1/watchlists/#{wl.id}", headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(user.watchlists.reload.count).to eq(1)
      expect(user.watchlists.first.name).to eq("Keep")
    end
  end

  describe "GET /api/v1/watchlists/tags" do
    it "returns matching tags" do
      wl = create(:watchlist, user: user)
      channel = create(:channel)
      create(:watchlist_channel, watchlist: wl, channel: channel)
      create(:watchlist_tags_note, watchlist: wl, channel: channel, tags: %w[gaming partner fps], added_at: Time.current)

      get "/api/v1/watchlists/tags", params: { q: "gam" }, headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to include("gaming")
    end
  end
end
