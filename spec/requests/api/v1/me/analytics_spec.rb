# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Me::Analytics", type: :request do
  let(:user) { create(:user) }

  def auth_headers(actor)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(actor.id)}" }
  end

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
  end

  describe "GET /api/v1/me/analytics/overview" do
    it "requires authentication" do
      get "/api/v1/me/analytics/overview"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns the overview payload (cold-start when no data)" do
      get "/api/v1/me/analytics/overview", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("meta", "cold_start")).to be(true)
    end

    it "returns 400 for an invalid window" do
      get "/api/v1/me/analytics/overview", params: { window: "bogus" }, headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end

    context "when the :pva flag is off" do
      before { allow(Flipper).to receive(:enabled?).with(:pva).and_return(false) }

      it "returns 404 (feature gated)" do
        get "/api/v1/me/analytics/overview", headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "POST /api/v1/me/analytics/engagement" do
    let(:body) do
      { events: [ { client_event_id: SecureRandom.uuid, event_type: "cheer", channel_id: "555",
                    amount: 100, occurred_at: Time.current.iso8601 } ],
        chat_activity: [ { channel_id: "555", date: "2026-05-28", message_count: 12,
                           first_seen_at: Time.current.iso8601, last_seen_at: Time.current.iso8601 } ] }
    end

    it "requires authentication" do
      post "/api/v1/me/analytics/engagement", params: body, as: :json
      expect(response).to have_http_status(:unauthorized)
    end

    it "accepts the client-capture batch and reports queued counts" do
      post "/api/v1/me/analytics/engagement", params: body, headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:accepted)
      expect(response.parsed_body.dig("queued", "events")).to eq(1)
      expect(response.parsed_body.dig("queued", "chat_activity")).to eq(1)
    end

    context "when the :pva flag is off" do
      before { allow(Flipper).to receive(:enabled?).with(:pva).and_return(false) }

      it "returns 404 (feature gated)" do
        post "/api/v1/me/analytics/engagement", params: body, headers: auth_headers(user), as: :json
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
