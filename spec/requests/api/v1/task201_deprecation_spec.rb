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

    it "sets Sunset header (RFC 7231 IMF-fixdate, 2026-06-11 = Thursday)" do
      perform_request
      expect(response.headers["Sunset"]).to eq("Thu, 11 Jun 2026 00:00:00 GMT")
    end

    it "sets Deprecation: true header" do
      perform_request
      expect(response.headers["Deprecation"]).to eq("true")
    end

    it "sets Cache-Control: no-store (RFC 7234 §4.2.2 — 410 default heuristic cacheable)" do
      perform_request
      expect(response.headers["Cache-Control"]).to eq("no-store")
    end

    it "does NOT raise Pundit::AuthorizationNotPerformedError (skip_authorization called)" do
      # Wrapper short-circuits before `authorize @channel, :…?` — Pundit's
      # `after_action :verify_authorized` would otherwise log a warning per hit
      # and pollute Loki/Grafana. `skip_authorization` in the concern silences it.
      expect { perform_request }.not_to raise_error
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

    context "when :hs_recommendations Flipper re-enabled (emergency rollback path)" do
      before { Flipper.enable(:hs_recommendations) }

      # Guards rollback path across all 3 endpoints (CR Nit #3): the deprecation
      # wrapper must NOT short-circuit when the Flipper is re-enabled. Downstream
      # services may 200 / 4xx / 5xx or raise in test env without seeds — any of
      # those proves control flow reached the action body. The wrapper-rendered
      # 410 would be observable as `response.body` containing "endpoint_removed";
      # absent that, rollback is intact.
      it "no longer renders the 410 deprecation body — defers to existing handler" do
        perform_request
      rescue StandardError
        # Downstream raised (e.g. SignalConfiguration::ConfigurationMissing) →
        # wrapper definitively did NOT render 410. Test passes by reaching here.
      ensure
        if response&.body.present?
          expect(response.body).not_to include("endpoint_removed")
          expect(response.headers["Sunset"]).to be_nil
        end
      end
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
