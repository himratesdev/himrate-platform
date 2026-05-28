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

  describe "POST /api/v1/me/analytics/cold_start/retry" do
    it "returns 401 без auth" do
      post "/api/v1/me/analytics/cold_start/retry"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects invalid source key" do
      post "/api/v1/me/analytics/cold_start/retry",
        params: { source: "invalid" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("InvalidSource")
    end

    it 'для "all": resets state + enqueues parent EnrollmentBackfillWorker' do
      PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
      expect(PersonalAnalytics::Enrollment::EnrollmentBackfillWorker).to receive(:perform_async)
        .with(user.id, true)

      post "/api/v1/me/analytics/cold_start/retry",
        params: { source: "all" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["ok"]).to be true
      expect(body["retried"]).to eq("all")
    end

    it 'для source_1: resets source cell + enqueues HelixFollowsBackfillWorker' do
      PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
      PersonalAnalytics::Enrollment::StateStore.update_source(
        user_id: user.id, source_key: "source_1",
        payload: { status: "failed", error_class: "TestFailure" }
      )
      expect(PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker).to receive(:perform_async).with(user.id)

      post "/api/v1/me/analytics/cold_start/retry",
        params: { source: "source_1" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)

      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state.sources["source_1"]["status"]).to eq("pending")
      expect(state.sources["source_1"]["error_class"]).to be_nil
    end

    it 'для source_5 (extension-driven): resets state без backend worker enqueue' do
      PersonalAnalytics::Enrollment::StateStore.initiate(user_id: user.id)
      # Critical assertion: no worker enqueue
      expect(PersonalAnalytics::Enrollment::HelixFollowsBackfillWorker).not_to receive(:perform_async)
      expect(PersonalAnalytics::Enrollment::GqlChannelShellBatchWorker).not_to receive(:perform_async)
      expect(PersonalAnalytics::Enrollment::EnrollmentBackfillWorker).not_to receive(:perform_async)

      post "/api/v1/me/analytics/cold_start/retry",
        params: { source: "source_5" }, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["retried"]).to eq("source_5")

      state = PvaEnrollmentBackfillState.find_by(user_id: user.id)
      expect(state.sources["source_5"]["status"]).to eq("pending")
    end

    it "rejects retry если no enrollment state exists (per-source path)" do
      post "/api/v1/me/analytics/cold_start/retry",
        params: { source: "source_1" }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("NoEnrollmentState")
    end
  end
end
