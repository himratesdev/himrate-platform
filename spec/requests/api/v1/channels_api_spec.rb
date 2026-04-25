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
    # rails_helper enables ALL_FLAGS by default (incl. pundit_authorization). Use
    # call_original для других gates (e.g. BUG-012 billing_auto_subscription_creation
    # — HOOK_FLAG, default OFF, individual specs enable as needed).
    allow(Flipper).to receive(:enabled?).and_call_original
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

    # TC-004: Free user during live stream → drill_down (signal_breakdown visible)
    it "returns drill_down with signal_breakdown for Free user during live stream" do
      Stream.create!(channel: channel, started_at: 30.minutes.ago) # live stream (no ended_at)
      TrustIndexHistory.create!(channel: channel, stream: channel.streams.last, trust_index_score: 72,
        confidence: 0.9, signal_breakdown: { "auth_ratio" => { "value" => 0.15 } },
        calculated_at: 5.minutes.ago, classification: "needs_review", cold_start_status: "full", erv_percent: 72.0)

      get "/api/v1/channels/#{channel.id}", headers: headers
      expect(response).to have_http_status(:ok)
      ti = response.parsed_body["data"]["trust_index"]
      expect(ti).to have_key("signal_breakdown")
      expect(ti["signal_breakdown"]).to have_key("auth_ratio")
    end

    # TC-005: Premium user tracking channel → full (recent_streams visible)
    it "returns full with recent_streams for Premium user tracking channel" do
      sub = Subscription.create!(user: premium_user, tier: "premium", is_active: true, started_at: Time.current)
      TrackedChannel.create!(user: premium_user, channel: channel, tracking_enabled: true, added_at: Time.current, subscription: sub)
      Stream.create!(channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)

      get "/api/v1/channels/#{channel.id}", headers: premium_headers
      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data).to have_key("recent_streams")
      expect(data).to have_key("tracked_since")
    end
  end

  describe "GET /api/v1/channels" do
    let(:user_sub) { create(:subscription, user: user, is_active: true) }

    it "returns tracked channels for authenticated user" do
      create(:tracked_channel, user: user, channel: channel, subscription: user_sub, tracking_enabled: true)
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
      sub = create(:subscription, user: user, is_active: true)
      3.times do |i|
        ch = Channel.create!(twitch_id: "pag#{i}", login: "pag#{i}", display_name: "Pag#{i}")
        create(:tracked_channel, user: user, channel: ch, subscription: sub, tracking_enabled: true)
      end
      get "/api/v1/channels", params: { page: 1, per_page: 2 }, headers: headers
      expect(response.parsed_body["data"].size).to eq(2)
      expect(response.parsed_body["meta"]["total"]).to eq(3)
      expect(response.parsed_body["meta"]["total_pages"]).to eq(2)
    end
  end

  describe "POST /api/v1/channels/:id/track" do
    # BUG-012 / CR N-4: auto-create Subscription gated Flipper flag
    # billing_auto_subscription_creation. Tests которые depend на auto-create
    # explicitly enable flag. Tests с pre-existing Subscription работают независимо.
    context "with billing_auto_subscription_creation enabled" do
      before { Flipper.enable(:billing_auto_subscription_creation) }

      it "creates tracked channel for premium user (auto-creates Subscription)" do
        expect {
          post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
        }.to change(Subscription, :count).by(1)
          .and change(TrackedChannel, :count).by(1)

        expect(response).to have_http_status(:created)
        tc = TrackedChannel.find_by(user: premium_user, channel: channel)
        expect(tc).to be_present
        expect(tc.subscription_id).to eq(Subscription.where(user: premium_user, is_active: true).first.id)
      end
    end

    it "reuses existing active Subscription when tracking second channel" do
      sub = create(:subscription, user: premium_user, is_active: true)
      another_channel = Channel.create!(twitch_id: "ch2", login: "another", display_name: "Another")

      expect {
        post "/api/v1/channels/#{another_channel.id}/track", headers: premium_headers
      }.to change(TrackedChannel, :count).by(1)
        .and change(Subscription, :count).by(0)

      tc = TrackedChannel.find_by(user: premium_user, channel: another_channel)
      expect(tc.subscription_id).to eq(sub.id)
    end

    # CR N-4 + PG-iter1: production safety — flag OFF + missing Subscription
    # → 402 Payment Required (BillingNotConfigured rescued в class header).
    # Loud machine-readable signal — frontend может surface user-friendly retry,
    # operator catches in Sentry via Rails.error.report.
    it "returns 402 Payment Required when flag OFF + no existing Subscription (production safety)" do
      # Flag НЕ enabled (HOOK_FLAGS default OFF), no pre-existing Subscription.
      post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body["error"]).to eq("BILLING_NOT_CONFIGURED")
    end

    it "returns 403 for free user" do
      post "/api/v1/channels/#{channel.id}/track", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 409 when already tracked" do
      sub = create(:subscription, user: premium_user, is_active: true)
      create(:tracked_channel, user: premium_user, channel: channel, subscription: sub, tracking_enabled: true)
      post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
      expect(response).to have_http_status(:conflict)
    end

    it "re-tracking with valid pre-existing Subscription works (no flag needed)" do
      sub = create(:subscription, user: premium_user, is_active: true)
      tc = create(:tracked_channel, user: premium_user, channel: channel, subscription: sub, tracking_enabled: false, added_at: 1.week.ago)

      post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
      expect(response).to have_http_status(:created)
      expect(tc.reload.tracking_enabled).to be true
    end
  end

  describe "DELETE /api/v1/channels/:id/track" do
    it "disables tracking (soft delete, preserves record)" do
      sub = create(:subscription, user: user, is_active: true)
      create(:tracked_channel, user: user, channel: channel, subscription: sub, tracking_enabled: true)

      delete "/api/v1/channels/#{channel.id}/track", headers: headers
      expect(response).to have_http_status(:ok)
      # Record preserved but tracking_enabled = false
      tc = TrackedChannel.find_by(user: user, channel: channel)
      expect(tc).to be_present
      expect(tc.tracking_enabled).to be false
    end

    it "returns 404 when not tracked" do
      delete "/api/v1/channels/#{channel.id}/track", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "re-tracking after untrack re-enables record" do
      sub = create(:subscription, user: premium_user, is_active: true)
      tc = create(:tracked_channel, user: premium_user, channel: channel, subscription: sub, tracking_enabled: false, added_at: 1.week.ago)

      post "/api/v1/channels/#{channel.id}/track", headers: premium_headers
      expect(response).to have_http_status(:created)
      expect(tc.reload.tracking_enabled).to be true
    end
  end
end
