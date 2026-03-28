# frozen_string_literal: true

require "rails_helper"

RSpec.describe "POST /api/v1/analytics/auth_events", type: :request do
  let(:valid_params) do
    { provider: "twitch", result: "failure", error_type: "network", extension_version: "0.1.0" }
  end

  it "creates auth event" do
    expect {
      post "/api/v1/analytics/auth_events", params: valid_params, as: :json
    }.to change(AuthEvent, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(AuthEvent.last.provider).to eq("twitch")
    expect(AuthEvent.last.result).to eq("failure")
    expect(AuthEvent.last.ip_address).to be_present
  end

  it "rejects invalid provider" do
    post "/api/v1/analytics/auth_events", params: { provider: "invalid", result: "attempt" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "works without auth (anonymous user)" do
    post "/api/v1/analytics/auth_events", params: valid_params, as: :json
    expect(response).to have_http_status(:created)
    expect(AuthEvent.last.user_id).to be_nil
  end

  context "consecutive failure detection" do
    it "logs warning on 2+ failures from same IP" do
      create(:auth_event, result: "failure", ip_address: "1.2.3.4", created_at: 2.minutes.ago)

      expect(Rails.logger).to receive(:warn).with(/Auth alert: 2 consecutive failures/)

      post "/api/v1/analytics/auth_events",
        params: valid_params,
        headers: { "REMOTE_ADDR" => "1.2.3.4" },
        as: :json
    end
  end
end
