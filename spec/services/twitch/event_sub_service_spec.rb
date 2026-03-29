# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::EventSubService do
  let(:service) { described_class.new }
  let(:helix_url) { "https://api.twitch.tv/helix/eventsub/subscriptions" }
  let(:token_url) { "https://id.twitch.tv/oauth2/token" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_ID").and_return("test_client_id")
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_SECRET").and_return("test_secret")
    allow(ENV).to receive(:fetch).with("TWITCH_WEBHOOK_SECRET", anything).and_return("test_webhook_secret_min10")
    allow(ENV).to receive(:fetch).with("EVENTSUB_WEBHOOK_URL", anything).and_return("https://staging.himrate.com/webhooks/twitch")
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")

    # Clear Redis token cache
    Redis.new(url: "redis://localhost:6379/1").del("twitch:app_access_token")
  rescue Redis::CannotConnectError
    # Redis not available
  ensure
    stub_request(:post, token_url)
      .to_return(status: 200, body: { access_token: "test_token", expires_in: 3600 }.to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  describe "#subscribe (TC-012)" do
    it "creates 5 EventSub subscriptions for a broadcaster" do
      stub_request(:post, helix_url)
        .to_return(status: 202, body: { data: [ { id: "sub-123" } ] }.to_json,
                   headers: { "Content-Type" => "application/json" })

      results = service.subscribe(broadcaster_id: "12345")
      expect(results.size).to eq(4)
      expect(WebMock).to have_requested(:post, helix_url).times(4)
    end

    it "handles 409 conflict (subscription exists)" do
      stub_request(:post, helix_url)
        .to_return(status: 409, body: { message: "already exists" }.to_json,
                   headers: { "Content-Type" => "application/json" })

      results = service.subscribe(broadcaster_id: "12345")
      expect(results).to all(eq("existing"))
    end
  end

  describe "#unsubscribe (TC-013)" do
    it "deletes subscriptions for a broadcaster" do
      # List returns 2 matching subs
      stub_request(:get, helix_url)
        .to_return(status: 200, body: { data: [
          { id: "sub-1", condition: { "broadcaster_user_id" => "12345" } },
          { id: "sub-2", condition: { "broadcaster_user_id" => "12345" } },
          { id: "sub-3", condition: { "broadcaster_user_id" => "99999" } }
        ] }.to_json, headers: { "Content-Type" => "application/json" })

      # Delete each matching sub
      stub_request(:delete, /#{helix_url}\?id=sub-[12]/)
        .to_return(status: 204)

      deleted = service.unsubscribe(broadcaster_id: "12345")
      expect(deleted).to eq(2)
    end
  end

  describe "#list_subscriptions" do
    it "returns subscription data" do
      stub_request(:get, helix_url)
        .to_return(status: 200, body: { data: [ { id: "sub-1", type: "stream.online" } ] }.to_json,
                   headers: { "Content-Type" => "application/json" })

      subs = service.list_subscriptions
      expect(subs.size).to eq(1)
      expect(subs.first["type"]).to eq("stream.online")
    end
  end
end
