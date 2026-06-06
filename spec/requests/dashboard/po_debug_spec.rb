# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dashboard::PoDebug", type: :request do
  let(:user_env) { "po" }
  let(:pass_env) { "test-secret-123" }
  let(:basic_auth) { ActionController::HttpAuthentication::Basic.encode_credentials(user_env, pass_env) }

  before do
    Rails.cache.clear
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PO_DEBUG_USER", "po").and_return(user_env)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("PO_DEBUG_PASSWORD").and_return(pass_env)

    # Stub collectors to keep request spec hermetic.
    allow(PoDebug::Aggregator).to receive(:call).and_return(
      generated_at: Time.current.iso8601,
      version: "v0.1-hot-lite",
      stream: { state: "offline" },
      pipeline: { stub: true },
      viewers: { stub: true },
      queues: { global: {}, queues: [] },
      vps: { load: {}, memory: {}, swap: {}, disk: {} },
      writes_log: { stub: true },
      errors: { stub: true }
    )
  end

  describe "GET /dashboard/po-debug" do
    context "when flag is OFF" do
      before { Flipper.disable(:po_debug_dashboard) }

      it "returns 503 with informative plain message" do
        get "/dashboard/po-debug", headers: { "Authorization" => basic_auth }
        expect(response).to have_http_status(:service_unavailable)
        expect(response.body).to include("po_debug_dashboard flag disabled")
      end
    end

    context "when flag is ON" do
      before { Flipper.enable(:po_debug_dashboard) }

      it "returns 200 + renders HTML when Basic Auth passes" do
        get "/dashboard/po-debug", headers: { "Authorization" => basic_auth }
        expect(response).to have_http_status(:ok)
        expect(response.body).to include("PO Debug Dashboard")
        expect(response.body).to include("v0.1-hot-lite")
      end

      it "returns JSON snapshot for .json format" do
        get "/dashboard/po-debug.json", headers: { "Authorization" => basic_auth }
        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body).to include("generated_at", "stream", "queues", "vps")
      end

      it "returns 401 without Basic Auth" do
        get "/dashboard/po-debug"
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 503 when PO_DEBUG_PASSWORD env is empty" do
        allow(ENV).to receive(:[]).with("PO_DEBUG_PASSWORD").and_return("")
        get "/dashboard/po-debug", headers: {
          "Authorization" => ActionController::HttpAuthentication::Basic.encode_credentials("po", "")
        }
        expect(response).to have_http_status(:service_unavailable)
        expect(response.body).to include("PO_DEBUG_PASSWORD not configured")
      end
    end
  end
end
