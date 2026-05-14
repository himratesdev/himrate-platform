# frozen_string_literal: true

require "rails_helper"

# TASK-201 Phase 1 (ADR-201, §4.1 + SRS v1.1 TC-018, FR-023, FR-012..014):
# 410 Gone transition for HS / Streamer Rating / Rehabilitation endpoints when
# :hs_recommendations Flipper is OFF. Spec covers all 3 deprecated endpoints
# и проверяет Sunset / Deprecation headers + JSON body shape per RFC 8594.
RSpec.describe "TASK-201 deprecated endpoint 410 transition", type: :request do
  let(:channel) { create(:channel) }
  let(:user_premium) { create(:user, tier: "premium") }
  let(:headers_premium) { auth_headers(user_premium) }

  before do
    # rails_helper enables :hs_recommendations by default — toggle OFF to
    # exercise Phase 1 transition path.
    Flipper.disable(:hs_recommendations)
    # No pushgateway in test env (same pattern as accessory_ops / cleanup_worker specs).
    allow(PrometheusMetrics).to receive(:observe_task201_endpoint_hit)
    create(:tracked_channel, user: user_premium, channel: channel, tracking_enabled: true)
    create(:subscription, user: user_premium, tier: "premium", is_active: true)
  end

  shared_examples "TASK-201 410 Gone response" do
    it "returns 410 Gone" do
      perform_request
      expect(response).to have_http_status(:gone)
    end

    it "sets Sunset header (RFC 8594, 2026-06-11)" do
      perform_request
      expect(response.headers["Sunset"]).to eq("Wed, 11 Jun 2026 00:00:00 GMT")
    end

    it "sets Deprecation: true header" do
      perform_request
      expect(response.headers["Deprecation"]).to eq("true")
    end

    it "returns structured JSON body" do
      perform_request
      body = response.parsed_body
      expect(body["error"]).to eq("endpoint_removed")
      expect(body["message"]).to include("philosophy v2")
      expect(body["deprecated_at"]).to eq("2026-05-14")
      expect(body["sunset_at"]).to eq("2026-06-11")
    end

    it "short-circuits before authenticate_user! (unauthenticated → still 410)" do
      perform_request_unauthenticated
      expect(response).to have_http_status(:gone)
    end
  end

  describe "GET /api/v1/channels/:id/health_score" do
    def perform_request
      get "/api/v1/channels/#{channel.id}/health_score", headers: headers_premium
    end

    def perform_request_unauthenticated
      get "/api/v1/channels/#{channel.id}/health_score"
    end

    include_examples "TASK-201 410 Gone response"

    context "when :hs_recommendations Flipper re-enabled (emergency rollback)" do
      before { Flipper.enable(:hs_recommendations) }

      it "no longer returns 410 — defers to existing handler" do
        perform_request
        # Existing handler proceeds — may be 200/403/422 depending on data
        # state, but NOT 410. Test guards rollback path stays open.
        expect(response).not_to have_http_status(:gone)
      end
    end
  end

  describe "POST /api/v1/channels/:id/health_score/recommendations/:rule_id/dismiss" do
    def perform_request
      post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-12/dismiss",
           headers: headers_premium
    end

    def perform_request_unauthenticated
      post "/api/v1/channels/#{channel.id}/health_score/recommendations/R-12/dismiss"
    end

    include_examples "TASK-201 410 Gone response"
  end

  describe "GET /api/v1/channels/:id/trends/rehabilitation" do
    def perform_request
      get "/api/v1/channels/#{channel.id}/trends/rehabilitation", headers: headers_premium
    end

    def perform_request_unauthenticated
      get "/api/v1/channels/#{channel.id}/trends/rehabilitation"
    end

    include_examples "TASK-201 410 Gone response"
  end

  # Sibling Trends endpoints (`/trends/erv`, `/trust_index`, `/anomalies`,
  # `/components`, `/stability`, `/comparison`, `/categories`, `/weekday`,
  # `/insights`) are NOT touched by `prepend_before_action :only: :rehabilitation`
  # — verified by reading `app/controllers/api/v1/channels/trends_controller.rb`
  # filter scope. Full regression coverage of those endpoints is in
  # `spec/requests/api/v1/trends_api_*_spec.rb` (CI guard).

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
