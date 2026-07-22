# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Social::Attribution", type: :request do
  let(:login) { "recrent" }
  let(:headers) { { "Accept" => "application/json" } }

  before do
    Rails.cache.delete(SocialAnalytics::ProfileRefreshWorker.cache_key(login))
    Rails.cache.delete(SocialAnalytics::ProfileRefreshWorker.pending_key(login))
  end

  it "reports pending and enqueues one warm-up on a cold cache (public, no auth)" do
    expect(SocialAnalytics::ProfileRefreshWorker).to receive(:perform_async).with(login).once

    get "/api/v1/social/streamers/#{login}/attribution", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("pending")
  end

  it "does not double-enqueue while a refresh is already pending" do
    allow(SocialAnalytics::ProfileRefreshWorker).to receive(:perform_async)
    get "/api/v1/social/streamers/#{login}/attribution", headers: headers # sets pending marker
    expect(SocialAnalytics::ProfileRefreshWorker).not_to receive(:perform_async)
    get "/api/v1/social/streamers/#{login}/attribution", headers: headers
    expect(response.parsed_body.dig("data", "status")).to eq("pending")
  end

  it "computes the funnel from the warmed cache + streams (temporal correlation, not causation)" do
    channel = create(:channel, login: login)
    stream_at = Time.utc(2026, 7, 20, 12, 0, 0)
    create(:stream, channel: channel, started_at: stream_at, ended_at: stream_at + 3.hours)

    Rails.cache.write(
      SocialAnalytics::ProfileRefreshWorker.cache_key(login),
      { login: login,
        platforms: { telegram: { available: true, recent_posts: [ { views: 300_000, at: (stream_at + 6.hours).iso8601 } ] } } }
    )

    get "/api/v1/social/streamers/#{login}/attribution", headers: headers

    body = response.parsed_body
    expect(response).to have_http_status(:ok)
    expect(body.dig("data", "status")).to eq("ready")
    expect(body.dig("data", "login")).to eq(login)
    expect(body.dig("data", "streams_in_window")).to eq(1)
    expect(body.dig("data", "telegram", "stream_associated_post_count")).to eq(1)
    expect(body.dig("data", "disclaimer")).to include("временная корреляция")
  end
end
