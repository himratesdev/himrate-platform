# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Me::Analytics::ColdStart" do
  let(:user) { create(:user) }
  let(:access_token) { Auth::JwtService.encode_access(user.id) }
  let(:headers) { { "Authorization" => "Bearer #{access_token}" } }

  describe "GET /api/v1/me/analytics/cold_start/state" do
    it "returns 401 без auth" do
      get "/api/v1/me/analytics/cold_start/state"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns not_started если state не создана" do
      get "/api/v1/me/analytics/cold_start/state", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["overall_status"]).to eq("not_started")
    end

    it "returns per-source state когда orchestrator initialized" do
      PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)

      get "/api/v1/me/analytics/cold_start/state", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["overall_status"]).to eq("pending")
      expect(body["sources"].keys).to match_array(%w[source_1 source_2 source_5])
    end
  end

  describe "POST /api/v1/me/analytics/cold_start/subs_payload" do
    before { PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id) }

    it "returns 401 без auth" do
      post "/api/v1/me/analytics/cold_start/subs_payload"
      expect(response).to have_http_status(:unauthorized)
    end

    it "accepts source #5 Apollo walk payload + upserts ChannelTenure" do
      payload = {
        source: 5,
        subscriptions: [
          { channel_twitch_id: "12345", channel_login: "shroud", channel_display_name: "shroud",
            tier: "1000", cumulative_months: 21 }
        ]
      }

      post "/api/v1/me/analytics/cold_start/subs_payload", params: payload, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["ok"]).to be true
      expect(body["rows_affected"]).to eq(1)

      tenure = ChannelTenure.find_by(user_id: user.id)
      expect(tenure.months).to eq(21)
    end

    it "rejects invalid source" do
      post "/api/v1/me/analytics/cold_start/subs_payload",
        params: { source: 99, subscriptions: [] }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
