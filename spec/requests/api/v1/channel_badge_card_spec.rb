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

  describe "GET /api/v1/channels/:id/card" do
    context "when streamer owns channel" do
      let(:user) { create(:user, role: "streamer") }

      before do
        create(:auth_provider, user: user, provider: "twitch", provider_id: channel.twitch_id)
      end

      it "returns full channel card data" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)

        data = response.parsed_body["data"]
        expect(data).to have_key("channel")
        expect(data).to have_key("trust")
        expect(data).to have_key("stats")
        expect(data).to have_key("recent_streams")
        expect(data).to have_key("badge_url")
        expect(data["channel"]["login"]).to eq(channel.login)
      end
    end

    context "when user does not own channel" do
      let(:user) { create(:user) }

      it "returns 403" do
        get "/api/v1/channels/#{channel.id}/card", headers: auth_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
