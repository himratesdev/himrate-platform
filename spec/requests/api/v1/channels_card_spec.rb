# frozen_string_literal: true

require "rails_helper"

# T1-061: universal layered card endpoint — guest-accessible, surface-aware.
RSpec.describe "Channel Card API (T1-061)", type: :request do
  let(:channel) { create(:channel) }

  before do
    stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago)
    create(:trust_index_history, channel: channel, stream: stream,
                                 authenticity: 90, ccv: 4200, calculated_at: 1.minute.ago)
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

  # Live 2026-09-19: a years-old channel read «создан 3 дня назад» — the card was serving our own
  # row timestamp as the channel's age.
  describe "channel.created_at — the Twitch account date, never our row timestamp" do
    it "serves the Twitch account creation date" do
      channel.update!(twitch_created_at: Time.utc(2014, 5, 7, 12, 0, 0))

      get "/api/v1/channels/#{channel.id}/card"

      expect(response.parsed_body.dig("data", "channel", "created_at")).to eq("2014-05-07T12:00:00Z")
    end

    it "is null while Twitch has not been asked yet — no fallback to the row timestamp" do
      channel.update!(twitch_created_at: nil)

      get "/api/v1/channels/#{channel.id}/card"

      meta = response.parsed_body.dig("data", "channel")
      expect(meta).to have_key("created_at")
      expect(meta["created_at"]).to be_nil
    end
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
