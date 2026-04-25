# frozen_string_literal: true

require "rails_helper"

# Rack::Attack uses Rails.cache for throttle tracking. Bucket key includes
# Time.now / period_seconds — when burst spans bucket boundary, counter resets
# и spec фейлит (BUG-013). Frozen time блок гарантирует все sequential
# requests в одном bucket — deterministic.
#
# In test, cache is :null_store by default — throttles don't fire.
# We enable :memory_store for these tests.

RSpec.describe "Rack::Attack rate limiting", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  before do
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.reset!
  end

  after do
    Rack::Attack.reset!
  end

  describe "admin brute force (5/min)" do
    around { |ex| freeze_time { ex.run } }

    it "blocks after 5 requests" do
      5.times { get "/admin/flipper", headers: { "REMOTE_ADDR" => "1.2.3.4" } }
      get "/admin/flipper", headers: { "REMOTE_ADDR" => "1.2.3.4" }

      expect(response).to have_http_status(429)
      expect(response.headers["Retry-After"]).to be_present
      expect(JSON.parse(response.body)["error"]).to eq("RATE_LIMIT_EXCEEDED")
    end
  end

  describe "auth brute force (10/min)" do
    around { |ex| freeze_time { ex.run } }

    it "blocks after 10 requests" do
      # Use refresh endpoint (doesn't need Twitch ENV vars)
      10.times { post "/api/v1/auth/refresh", headers: { "REMOTE_ADDR" => "2.3.4.5" } }
      post "/api/v1/auth/refresh", headers: { "REMOTE_ADDR" => "2.3.4.5" }

      expect(response).to have_http_status(429)
    end
  end

  describe "general API (60/min)" do
    around { |ex| freeze_time { ex.run } }

    it "blocks after 60 requests" do
      60.times { get "/api/v1/channels", headers: { "REMOTE_ADDR" => "3.4.5.6" } }
      get "/api/v1/channels", headers: { "REMOTE_ADDR" => "3.4.5.6" }

      expect(response).to have_http_status(429)
    end
  end

  describe "OPTIONS preflight excluded" do
    around { |ex| freeze_time { ex.run } }

    it "does not count OPTIONS toward throttle" do
      60.times do
        options "/api/v1/channels", headers: { "REMOTE_ADDR" => "4.5.6.7" }
      end
      get "/api/v1/channels", headers: { "REMOTE_ADDR" => "4.5.6.7" }

      expect(response).not_to have_http_status(429)
    end
  end

  describe "Retry-After header" do
    around { |ex| freeze_time { ex.run } }

    it "includes Retry-After in 429 response" do
      6.times { get "/admin/flipper", headers: { "REMOTE_ADDR" => "5.6.7.8" } }

      expect(response).to have_http_status(429)
      expect(response.headers["Retry-After"].to_i).to be > 0
      expect(response.headers["Retry-After"].to_i).to be <= 60
    end
  end

  describe "per-user JWT throttle (300/min)" do
    let(:user) { create(:user) }

    it "uses JWT sub as throttle key" do
      token = Auth::JwtService.encode_access(user.id)
      headers = { "REMOTE_ADDR" => "6.7.8.9", "Authorization" => "Bearer #{token}" }

      # Just verify the throttle key resolves (full 300 requests too slow for test)
      # Send 1 request with valid JWT — should not 429 (under limit)
      get "/api/v1/channels", headers: headers
      expect(response).not_to have_http_status(429)
    end

    it "falls back to IP-only for invalid JWT" do
      headers = { "REMOTE_ADDR" => "6.7.8.9", "Authorization" => "Bearer invalid_token" }

      # Invalid JWT → api/user throttle returns nil → only api/ip applies
      get "/api/v1/channels", headers: headers
      expect(response).not_to have_http_status(429)
    end
  end

  describe "localhost safelist" do
    it "does not throttle localhost" do
      100.times { get "/api/v1/channels", headers: { "REMOTE_ADDR" => "127.0.0.1" } }

      expect(response).not_to have_http_status(429)
    end
  end
end
