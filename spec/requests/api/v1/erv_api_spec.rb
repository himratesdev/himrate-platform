# frozen_string_literal: true

require "rails_helper"

# V1-RETIRE (2026-09-02): /erv is v2-only — the payload is the native count contract
# {erv, erv_interval, authenticity, band(label_key), confirmed_anomaly, cold_start_tier,
# confidence_marker, engine_version}. The v1 confidence_display / erv_percent /
# erv_range_* wire fields are gone.
RSpec.describe "ERV API", type: :request do
  let(:channel) { create(:channel) }
  let(:user_free) { create(:user, tier: "free") }
  let(:headers_free) { auth_headers(user_free) }

  before do
    stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
    create(:trust_index_history,
      channel: channel,
      stream: stream,
      calculated_at: 1.minute.ago)
  end

  describe "GET /api/v1/channels/:id/erv" do
    # Free viewer on a LIVE channel → :details view (v2 headline + ccv + erv_breakdown)
    it "returns the v2 payload with details for a Free user during live stream" do
      get "/api/v1/channels/#{channel.id}/erv", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["erv"]).to eq(3600)
      expect(data["erv_interval"]).to eq({ "lo" => 3400, "hi" => 3800 })
      expect(data["authenticity"]).to eq(72.0)
      expect(data["band"]).to eq(
        { "row" => 4, "color" => "green", "label_key" => "band.green_no_anomaly", "sub" => nil }
      )
      expect(data["erv_label"]).to be_present
      expect(data["confirmed_anomaly"]).to eq({ "shown" => false })
      expect(data["cold_start_tier"]).to eq("full")
      expect(data["confidence_marker"]).to eq("reliable")
      expect(data["engine_version"]).to eq("v2")
      # :details extras
      expect(data["ccv"]).to eq(5000)
      expect(data["erv_breakdown"]).to eq(
        { "v" => 5000, "f_hard" => 120.0, "f_soft" => 1400.0, "f_hat" => 1400.0 }
      )
    end

    # Guest → headline only (v2 headline carries the verdict, no breakdown/ccv)
    it "returns headline for guest" do
      get "/api/v1/channels/#{channel.id}/erv"

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["erv"]).to eq(3600)
      expect(data["authenticity"]).to eq(72.0)
      expect(data["band"]["label_key"]).to eq("band.green_no_anomaly")
      expect(data["erv_label"]).to be_present
      # Guest should NOT get the details extras
      expect(data).not_to have_key("ccv")
      expect(data).not_to have_key("erv_breakdown")
    end

    # No v2 TIH at all → cold-start payload (grey band, explicit nils)
    it "returns the cold-start payload for a channel without any TIH" do
      cold_channel = create(:channel)

      get "/api/v1/channels/#{cold_channel.id}/erv", headers: headers_free

      expect(response).to have_http_status(:ok)
      data = response.parsed_body["data"]
      expect(data["cold_start"]).to be(true)
      expect(data["erv"]).to be_nil
      expect(data["authenticity"]).to be_nil
      expect(data["band"]).to eq(
        { "row" => 5, "color" => "grey", "label_key" => "band.grey_insufficient", "sub" => nil }
      )
      expect(data["cold_start_tier"]).to eq("insufficient")
      expect(data["confidence_marker"]).to eq("provisional")
      expect(data["engine_version"]).to eq("v2")
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
