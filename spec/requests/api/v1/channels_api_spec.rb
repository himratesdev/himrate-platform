# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Channels API", type: :request do
  let(:channel) { Channel.create!(twitch_id: "ch123", login: "testchannel", display_name: "Test Channel") }
  let(:user) { create(:user, role: "viewer", tier: "free") }
  let(:premium_user) { create(:user, role: "viewer", tier: "premium") }
  let(:token) { Auth::JwtService.encode_access(user.id) }
  let(:premium_token) { Auth::JwtService.encode_access(premium_user.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:premium_headers) { { "Authorization" => "Bearer #{premium_token}" } }

  before do
    allow(Flipper).to receive(:enabled?).with(:pundit_authorization).and_return(true)
  end

  describe "GET /api/v1/channels/:id" do
    it "returns headline for guest (no auth)" do
      get "/api/v1/channels/#{channel.id}"
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["login"]).to eq("testchannel")
      expect(data).to have_key("trust_index")
    end

    it "returns channel by login" do
      channel # force creation
      get "/api/v1/channels/testchannel"
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["login"]).to eq("testchannel")
    end

    it "returns channel by twitch_id param" do
      get "/api/v1/channels/#{channel.id}", params: { twitch_id: "ch123" }
      expect(response).to have_http_status(:ok)
    end

    it "returns 404 for unknown channel" do
      get "/api/v1/channels/nonexistent"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/v1/channels" do
    it "returns tracked channels for authenticated user" do
      TrackedChannel.create!(user: user, channel: channel, tracking_enabled: true, added_at: Time.current)
      get "/api/v1/channels", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].size).to eq(1)
      expect(response.parsed_body["meta"]["total"]).to eq(1)
    end

    it "returns empty array when no tracked channels" do
      get "/api/v1/channels", headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]).to eq([])
    end

    it "returns 401 without auth" do
      get "/api/v1/channels"
      expect(response).to have_http_status(:unauthorized)
    end

    it "supports pagination" do
      3.times do |i|
        ch = Channel.create!(twitch_id: "pag#{i}", login: "pag#{i}", display_name: "Pag#{i}")
        TrackedChannel.create!(user: user, channel: ch, tracking_enabled: true, added_at: Time.current)
      end
      get "/api/v1/channels", params: { page: 1, per_page: 2 }, headers: headers
      expect(response.parsed_body["data"].size).to eq(2)
      expect(response.parsed_body["meta"]["total"]).to eq(3)
      expect(response.parsed_body["meta"]["total_pages"]).to eq(2)
    end
  end

  describe "POST /api/v1/channels/:id/track" do
    it "creates tracked channel for premium user" do
      post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
      expect(response).to have_http_status(:created)
      expect(TrackedChannel.exists?(user: premium_user, channel: channel)).to be true
    end

    it "returns 403 for free user" do
      post "/api/v1/channels/#{channel.id}/track", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 409 when already tracked" do
      TrackedChannel.create!(user: premium_user, channel: channel, tracking_enabled: true, added_at: Time.current)
      post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
      expect(response).to have_http_status(:conflict)
    end
  end

  describe "DELETE /api/v1/channels/:id/track" do
    it "removes tracked channel" do
      sub = Subscription.create!(user: user, tier: "premium", is_active: true, started_at: Time.current)
      TrackedChannel.create!(user: user, channel: channel, tracking_enabled: true, added_at: Time.current, subscription: sub)

      delete "/api/v1/channels/#{channel.id}/track", headers: headers
      expect(response).to have_http_status(:ok)
      expect(TrackedChannel.exists?(user: user, channel: channel)).to be false
    end

    it "returns 404 when not tracked" do
      delete "/api/v1/channels/#{channel.id}/track", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end
end
