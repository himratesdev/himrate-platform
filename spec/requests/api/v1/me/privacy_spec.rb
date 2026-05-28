# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Me::Privacy", type: :request do
  let(:user) { create(:user) }

  def auth_headers(actor)
    { "Authorization" => "Bearer #{Auth::JwtService.encode_access(actor.id)}" }
  end

  before do
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:pva).and_return(true)
  end

  describe "GET /api/v1/me/privacy" do
    it "requires authentication" do
      get "/api/v1/me/privacy"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns DEFAULTS + cold meta when no row" do
      get "/api/v1/me/privacy", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "toggles", "display_name_visible")).to be(false)
      expect(response.parsed_body.dig("data", "toggles", "recognition")).to be(true)
      expect(response.parsed_body.dig("data", "consent_log")).to eq([])
      expect(response.parsed_body.dig("meta", "cold_start")).to be(true)
    end

    it "returns 404 when :pva is OFF" do
      allow(Flipper).to receive(:enabled?).with(:pva).and_return(false)
      get "/api/v1/me/privacy", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PUT /api/v1/me/privacy" do
    it "creates row + applies toggles + appends consent_log, returns fresh payload" do
      put "/api/v1/me/privacy", params: { toggles: { display_name_visible: true } },
        headers: auth_headers(user), as: :json

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "toggles", "display_name_visible")).to be(true)
      expect(response.parsed_body.dig("data", "consent_log").size).to eq(1)
      expect(response.parsed_body.dig("meta", "cold_start")).to be(false)
    end

    it "returns 400 for empty/invalid toggles" do
      put "/api/v1/me/privacy", params: { toggles: {} }, headers: auth_headers(user), as: :json
      expect(response).to have_http_status(:bad_request)
    end

    it "is idempotent — second identical PUT does not duplicate consent_log" do
      put "/api/v1/me/privacy", params: { toggles: { chat_capture: false } },
        headers: auth_headers(user), as: :json
      put "/api/v1/me/privacy", params: { toggles: { chat_capture: false } },
        headers: auth_headers(user), as: :json

      expect(response.parsed_body.dig("data", "consent_log").size).to eq(1)
    end
  end
end
