# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Channel Badge & Card API" do
  let(:channel) { create(:channel) }

  describe "GET /api/v1/channels/:id/badge" do
    context "when streamer owns channel" do
      let(:user) { create(:user, role: "streamer") }

      before do
        create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id)
      end

      it "returns badge embed data" do
        get "/api/v1/channels/#{channel.id}/badge", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)

        data = response.parsed_body["data"]
        expect(data).to have_key("html")
        expect(data).to have_key("markdown")
        expect(data).to have_key("bbcode")
        expect(data).to have_key("svg_url")
        expect(data["html"]).to include("himrate.com")
      end
    end

    context "when user does not own channel" do
      let(:user) { create(:user) }

      it "returns 403" do
        get "/api/v1/channels/#{channel.id}/badge", headers: auth_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET /api/v1/channels/:id/badge.svg" do
    it "returns SVG without authentication" do
      get "/api/v1/channels/#{channel.id}/badge.svg"
      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("image/svg+xml")
      expect(response.body).to include("<svg")
      expect(response.body).to include("HimRate")
    end
  end

  # T1-061: /card is now the universal LAYERED card-object (BREAKING vs old flat streamer-own card).
  # Free layers 1-3 to any viewer; paid layers 4-5 are dashboard-only (extension → open_dashboard CTA).
  describe "GET /api/v1/channels/:id/card" do
    context "when streamer owns channel (dashboard surface)" do
      let(:user) { create(:user, role: "streamer") }

      before do
        create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id)
      end

      it "returns the layered card with owner period_depth data" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user, surface: "dashboard")
        expect(response).to have_http_status(:ok)

        data = response.parsed_body["data"]
        expect(data).to have_key("channel")
        expect(data).to have_key("layers")
        expect(data).to have_key("badge_url")
        expect(data["channel"]["login"]).to eq(channel.login)

        layers = data["layers"]
        expect(layers["headline"]["available"]).to be(true)
        expect(layers["reputation"]["available"]).to be(true)
        # owner on dashboard → period_depth carries the former own-card stats + recent_streams.
        expect(layers["period_depth"]["available"]).to be(true)
        expect(layers["period_depth"]["data"]).to have_key("stats")
        expect(layers["period_depth"]["data"]).to have_key("recent_streams")
      end

      # T1-064 FR-1 + T1-061 FR-6: no orphaned Health Score, and NO premium reputation_band at top
      # level (reputation now comes from the T1-065 layer, not Trust(:full)/build_full).
      it "does not expose health_score or top-level premium reputation_band" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user, surface: "dashboard")
        data = response.parsed_body["data"]
        expect(data).not_to have_key("health_score")
        expect(data).not_to have_key("reputation_band")
      end

      # T1-064/T1-065: Reputation Categorical band via the reputation layer (HistoryService).
      it "exposes the Reputation band + trend via the reputation layer (T1-065)" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user, surface: "dashboard")
        rep = response.parsed_body.dig("data", "layers", "reputation", "data")
        expect(rep["current"]).to have_key("band")
        expect(rep).to have_key("trend")
      end
    end

    context "when streamer owns channel (extension surface)" do
      let(:user) { create(:user, role: "streamer") }

      before do
        create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id)
      end

      it "hides paid layers behind an open_dashboard CTA (never paywall in extension)" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user) # default = extension
        expect(response).to have_http_status(:ok)

        period = response.parsed_body.dig("data", "layers", "period_depth")
        expect(period["available"]).to be(false)
        expect(period["cta"]["action"]).to eq("open_dashboard")
      end
    end

    context "when user does not own channel (T1-061: layered, not 403)" do
      let(:user) { create(:user) }

      it "returns 200 with the free layers" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)

        layers = response.parsed_body.dig("data", "layers")
        expect(layers["headline"]["available"]).to be(true)
        expect(layers["reputation"]["available"]).to be(true)
      end
    end
  end

  private

  def auth_headers(user, surface: nil)
    token = surface ? Auth::JwtService.encode_access(user.id, surface: surface) : Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
