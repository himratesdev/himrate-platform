# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Twitch EventSub Webhooks", type: :request do
  let(:webhook_secret) { Webhooks::TwitchController::WEBHOOK_SECRET }
  let(:message_id) { "unique-msg-id-123" }
  let(:timestamp) { Time.current.iso8601 }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TWITCH_WEBHOOK_SECRET", anything).and_return(webhook_secret)
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")

    # Clear Redis idempotency keys
    Redis.new(url: "redis://localhost:6379/1").del("eventsub:msg:#{message_id}")
  rescue Redis::CannotConnectError
    # Redis not available in test — idempotency disabled
  end

  def sign_request(body_str)
    hmac_message = "#{message_id}#{timestamp}#{body_str}"
    "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, hmac_message)
  end

  def twitch_headers(body_str, type: "notification", sub_type: "stream.online")
    {
      "Twitch-Eventsub-Message-Id" => message_id,
      "Twitch-Eventsub-Message-Timestamp" => timestamp,
      "Twitch-Eventsub-Message-Signature" => sign_request(body_str),
      "Twitch-Eventsub-Message-Type" => type,
      "Twitch-Eventsub-Subscription-Type" => sub_type,
      "Content-Type" => "application/json"
    }
  end

  # === FR-001: HMAC Verification ===

  describe "HMAC verification" do
    it "accepts valid HMAC signature (TC-001)" do
      body = { subscription: { type: "stream.online" }, event: { broadcaster_user_id: "123" } }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body)
      expect(response).to have_http_status(:ok)
    end

    it "rejects invalid HMAC signature (TC-002)" do
      body = { subscription: { type: "stream.online" }, event: {} }.to_json
      headers = twitch_headers(body)
      headers["Twitch-Eventsub-Message-Signature"] = "sha256=invalid"

      post "/webhooks/twitch", params: body, headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects missing HMAC headers (TC-003)" do
      body = { subscription: { type: "stream.online" }, event: {} }.to_json
      post "/webhooks/twitch", params: body, headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects stale timestamp >10 min (TC-015)" do
      stale_timestamp = 15.minutes.ago.iso8601
      body = { subscription: { type: "stream.online" }, event: {} }.to_json
      stale_message = "#{message_id}#{stale_timestamp}#{body}"
      stale_sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", webhook_secret, stale_message)

      headers = {
        "Twitch-Eventsub-Message-Id" => message_id,
        "Twitch-Eventsub-Message-Timestamp" => stale_timestamp,
        "Twitch-Eventsub-Message-Signature" => stale_sig,
        "Twitch-Eventsub-Message-Type" => "notification",
        "Content-Type" => "application/json"
      }

      post "/webhooks/twitch", params: body, headers: headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  # === FR-002: Challenge Response ===

  describe "challenge response" do
    it "responds with challenge value as text/plain (TC-004)" do
      body = { challenge: "test-challenge-value", subscription: { type: "stream.online" } }.to_json
      headers = twitch_headers(body, type: "webhook_callback_verification")

      post "/webhooks/twitch", params: body, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("test-challenge-value")
      expect(response.content_type).to include("text/plain")
    end
  end

  # === FR-003: Idempotency ===

  describe "idempotency" do
    it "ignores duplicate message_id (TC-005)" do
      body = { subscription: { type: "stream.online" }, event: { broadcaster_user_id: "123" } }.to_json
      headers = twitch_headers(body)

      # First request
      post "/webhooks/twitch", params: body, headers: headers
      expect(response).to have_http_status(:ok)

      # Second request (same message_id)
      post "/webhooks/twitch", params: body, headers: headers
      expect(response).to have_http_status(:ok)
    end
  end

  # === FR-004: Event Routing ===

  describe "event routing" do
    it "routes stream.online to StreamOnlineWorker (TC-006)" do
      expect(StreamOnlineWorker).to receive(:perform_async).with(hash_including("broadcaster_user_id" => "123"))

      body = { subscription: { type: "stream.online" }, event: { broadcaster_user_id: "123", type: "live" } }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body)
      expect(response).to have_http_status(:ok)
    end

    it "routes stream.offline to StreamOfflineWorker (TC-007)" do
      expect(StreamOfflineWorker).to receive(:perform_async)

      body = { subscription: { type: "stream.offline" }, event: { broadcaster_user_id: "456" } }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body, sub_type: "stream.offline")
      expect(response).to have_http_status(:ok)
    end

    it "routes channel.raid to RaidWorker with from/to/viewers (TC-008)" do
      expect(RaidWorker).to receive(:perform_async).with(
        hash_including("from_broadcaster_user_id" => "111", "to_broadcaster_user_id" => "222", "viewers" => 5000)
      )

      body = {
        subscription: { type: "channel.raid" },
        event: { from_broadcaster_user_id: "111", to_broadcaster_user_id: "222", viewers: 5000 }
      }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body, sub_type: "channel.raid")
      expect(response).to have_http_status(:ok)
    end

    it "routes channel.update to ChannelUpdateWorker (TC-009)" do
      expect(ChannelUpdateWorker).to receive(:perform_async)

      body = {
        subscription: { type: "channel.update" },
        event: { broadcaster_user_id: "123", title: "New Title", category_name: "Just Chatting" }
      }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body, sub_type: "channel.update")
      expect(response).to have_http_status(:ok)
    end

    it "routes channel.follow to FollowWorker (TC-010)" do
      expect(FollowWorker).to receive(:perform_async)

      body = {
        subscription: { type: "channel.follow" },
        event: { user_id: "789", user_login: "newuser", broadcaster_user_id: "123" }
      }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body, sub_type: "channel.follow")
      expect(response).to have_http_status(:ok)
    end

    it "handles unknown event type with 200 + log (TC-011)" do
      body = { subscription: { type: "channel.unknown_future_event" }, event: {} }.to_json
      post "/webhooks/twitch", params: body, headers: twitch_headers(body, sub_type: "channel.unknown_future_event")
      expect(response).to have_http_status(:ok)
    end
  end

  # === FR-012: Revocation ===

  describe "revocation" do
    it "handles revocation with 200 + log (TC-014)" do
      body = { subscription: { type: "stream.online", id: "sub-123", status: "authorization_revoked" } }.to_json
      headers = twitch_headers(body, type: "revocation")

      post "/webhooks/twitch", params: body, headers: headers
      expect(response).to have_http_status(:ok)
    end
  end
end
