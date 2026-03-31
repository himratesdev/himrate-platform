# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ERV API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:headers_free) { auth_headers(user_free) }

  before do
    stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
    create(:trust_index_history,
      channel: channel,
      stream: stream,
      trust_index_score: 85.0,
      erv_percent: 85.0,
      ccv: 5000,
      confidence: 0.85,
      classification: "trusted",
      cold_start_status: "full",
      calculated_at: 1.minute.ago)
  end

  describe "GET /api/v1/channels/:id/erv" do
    # TC-016: confidence >= 0.7 → point estimate
    it "returns point estimate for high confidence" do
      get "/api/v1/channels/#{channel.id}/erv", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["erv_percent"]).to eq(85.0)
      expect(data["erv_label"]).to be_present
      expect(data["erv_label_color"]).to eq("green")
      expect(data["erv_count"]).to be_present
      expect(data["confidence_display"]["type"]).to eq("point")
    end

    # TC-017: confidence 0.3-0.6 → range ±15%
    it "returns range for medium confidence" do
      channel.trust_index_histories.update_all(confidence: 0.5)

      get "/api/v1/channels/#{channel.id}/erv", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["confidence_display"]["type"]).to eq("range")
      expect(data).to have_key("erv_range_low")
      expect(data).to have_key("erv_range_high")
    end

    # TC-018: confidence < 0.3 → insufficient
    it "returns insufficient for low confidence" do
      channel.trust_index_histories.update_all(confidence: 0.2)

      get "/api/v1/channels/#{channel.id}/erv", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["confidence_display"]["type"]).to eq("insufficient")
    end

    # Guest → headline only
    it "returns headline for guest" do
      get "/api/v1/channels/#{channel.id}/erv"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["erv_percent"]).to eq(85.0)
      expect(data["erv_label"]).to be_present
      # Guest should NOT get erv_count
      expect(data).not_to have_key("erv_count")
    end

    # ETag support
    it "returns 304 on second request with same ETag" do
      get "/api/v1/channels/#{channel.id}/erv"
      etag = response.headers["ETag"]

      get "/api/v1/channels/#{channel.id}/erv", headers: { "If-None-Match" => etag }
      expect(response).to have_http_status(:not_modified)
    end
  end

  private

  def auth_headers(user)
    token = Auth::JwtService.encode_access(user.id)
    { "Authorization" => "Bearer #{token}" }
  end
end
