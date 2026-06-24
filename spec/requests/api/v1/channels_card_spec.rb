# frozen_string_literal: true

require "rails_helper"

# T1-061: universal layered card endpoint — guest-accessible, surface-aware.
RSpec.describe "Channel Card API (T1-061)", type: :request do
  let(:channel) { create(:channel) }

  before do
    stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago)
    create(:trust_index_history, channel: channel, stream: stream,
                                 trust_index_score: 88, erv_percent: 90, ccv: 4200, calculated_at: 1.minute.ago)
  end

  it "is guest-accessible (no auth → 200, not 401) with the free layers" do
    get "/api/v1/channels/#{channel.id}/card"

    expect(response).to have_http_status(:ok)
    layers = response.parsed_body.dig("data", "layers")
    expect(layers["headline"]["available"]).to be(true)
    expect(layers["reputation"]["available"]).to be(true)
    # extension is the default surface → paid layers carry an open_dashboard CTA, never a paywall.
    expect(layers["period_depth"]["cta"]["action"]).to eq("open_dashboard")
  end

  it "returns 404 for an unknown channel" do
    get "/api/v1/channels/#{SecureRandom.uuid}/card"
    expect(response).to have_http_status(:not_found)
  end

  it "supports conditional requests (304 with matching ETag)" do
    get "/api/v1/channels/#{channel.id}/card"
    etag = response.headers["ETag"]
    expect(etag).to be_present

    get "/api/v1/channels/#{channel.id}/card", headers: { "If-None-Match" => etag }
    expect(response).to have_http_status(:not_modified)
  end
end
