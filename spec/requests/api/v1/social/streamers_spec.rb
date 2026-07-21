# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Social::Streamers", type: :request do
  let(:login) { "recrent" }
  let(:headers) { { "Accept" => "application/json" } }

  before do
    Rails.cache.delete(SocialAnalytics::ProfileRefreshWorker.cache_key(login))
    Rails.cache.delete(SocialAnalytics::ProfileRefreshWorker.pending_key(login))
  end

  it "reports pending and enqueues one warm-up on a cold cache (public, no auth)" do
    expect(SocialAnalytics::ProfileRefreshWorker).to receive(:perform_async).with(login).once

    get "/api/v1/social/streamers/#{login}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "status")).to eq("pending")
  end

  it "does not double-enqueue while a refresh is already pending" do
    allow(SocialAnalytics::ProfileRefreshWorker).to receive(:perform_async)
    get "/api/v1/social/streamers/#{login}", headers: headers # sets pending marker
    expect(SocialAnalytics::ProfileRefreshWorker).not_to receive(:perform_async)
    get "/api/v1/social/streamers/#{login}", headers: headers
    expect(response.parsed_body.dig("data", "status")).to eq("pending")
  end

  it "serves the warmed profile from cache" do
    Rails.cache.write(SocialAnalytics::ProfileRefreshWorker.cache_key(login),
                      { login: login, platforms: { telegram: { available: true, subscribers: 236_000 } },
                        generated_at: "2026-07-21T00:00:00Z" })

    get "/api/v1/social/streamers/#{login}", headers: headers

    body = response.parsed_body
    expect(body.dig("data", "status")).to eq("ready")
    expect(body.dig("data", "login")).to eq(login)
    expect(body.dig("data", "platforms", "telegram", "subscribers")).to eq(236_000)
  end
end
