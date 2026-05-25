# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::HelixClient do
  let(:client) { described_class.new }
  let(:token_response) { { access_token: "test_token", expires_in: 3600 }.to_json }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_ID").and_return("test_client_id")
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_SECRET").and_return("test_secret")
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")

    # Clear Redis token cache to prevent state leak between tests
    Redis.new(url: "redis://localhost:6379/1").del("twitch:app_access_token")
  rescue Redis::CannotConnectError
    # Redis not available in CI — tests still work (token fetched each time)
  ensure
    # Stub token request
    stub_request(:post, "https://id.twitch.tv/oauth2/token")
      .to_return(status: 200, body: token_response, headers: { "Content-Type" => "application/json" })
  end

  describe "#get_users" do
    it "returns user data by login" do
      stub_request(:get, "https://api.twitch.tv/helix/users?login=shroud")
        .to_return(
          status: 200,
          body: { data: [ { id: "12345", login: "shroud", display_name: "shroud", broadcaster_type: "partner" } ] }.to_json,
          headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "799" }
        )

      result = client.get_users(logins: [ "shroud" ])
      expect(result).to be_an(Array)
      expect(result.first["login"]).to eq("shroud")
    end

    it "returns nil for non-existent user" do
      stub_request(:get, "https://api.twitch.tv/helix/users?login=nonexistent_user_xyz")
        .to_return(
          status: 200,
          body: { data: [] }.to_json,
          headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "799" }
        )

      result = client.get_users(logins: [ "nonexistent_user_xyz" ])
      expect(result).to eq([])
    end
  end

  describe "#get_streams" do
    it "returns stream data" do
      stub_request(:get, "https://api.twitch.tv/helix/streams?user_login=shroud")
        .to_return(
          status: 200,
          body: { data: [ { user_login: "shroud", viewer_count: 32000, type: "live" } ] }.to_json,
          headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "798" }
        )

      result = client.get_streams(user_logins: [ "shroud" ])
      expect(result.first["viewer_count"]).to eq(32000)
    end
  end

  describe "#get_followers_count" do
    it "returns total followers" do
      stub_request(:get, "https://api.twitch.tv/helix/channels/followers?broadcaster_id=12345&first=1")
        .to_return(
          status: 200,
          body: { total: 9_500_000, data: [] }.to_json,
          headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "797" }
        )

      result = client.get_followers_count(broadcaster_id: "12345")
      expect(result).to eq(9_500_000)
    end
  end

  describe "error handling" do
    it "retries on 429 with exponential backoff" do
      stub_request(:get, "https://api.twitch.tv/helix/users?login=test")
        .to_return(
          { status: 429, headers: { "Ratelimit-Remaining" => "0" } },
          { status: 429, headers: { "Ratelimit-Remaining" => "0" } },
          { status: 200, body: { data: [ { login: "test" } ] }.to_json,
            headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "799" } }
        )

      allow(client).to receive(:sleep) # don't actually sleep in tests

      result = client.get_users(logins: [ "test" ])
      expect(result.first["login"]).to eq("test")
    end

    it "returns nil after max retries on 429" do
      stub_request(:get, "https://api.twitch.tv/helix/users?login=test")
        .to_return(status: 429, headers: { "Ratelimit-Remaining" => "0" })

      allow(client).to receive(:sleep)

      result = client.get_users(logins: [ "test" ])
      expect(result).to be_nil
    end

    it "auto-refreshes token on 401" do
      call_count = 0
      stub_request(:get, "https://api.twitch.tv/helix/users?login=test")
        .to_return(lambda { |_|
          call_count += 1
          if call_count == 1
            { status: 401 }
          else
            { status: 200, body: { data: [ { login: "test" } ] }.to_json,
              headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "799" } }
          end
        })

      result = client.get_users(logins: [ "test" ])
      expect(result.first["login"]).to eq("test")
    end

    it "returns nil on timeout" do
      stub_request(:get, "https://api.twitch.tv/helix/users?login=test")
        .to_timeout

      result = client.get_users(logins: [ "test" ])
      expect(result).to be_nil
    end

    # TASK-251.10: a 400 is a permanent client error, not transient. Default keeps the legacy
    # nil behavior; opt-in callers raise BadRequestError so they can isolate the offending id.
    context "on 400 Bad Request (Bad Identifiers)" do
      let(:bad_request_body) do
        { error: "Bad Request", status: 400, message: "Invalid username(s), email(s), or ID(s). Bad Identifiers." }.to_json
      end

      before do
        stub_request(:get, "https://api.twitch.tv/helix/users?id=qa31track")
          .to_return(status: 400, body: bad_request_body, headers: { "Content-Type" => "application/json" })
      end

      it "returns nil by default (back-compat for existing callers)" do
        expect(client.get_users(ids: [ "qa31track" ])).to be_nil
      end

      it "raises BadRequestError when raise_on_bad_request: true" do
        expect { client.get_users(ids: [ "qa31track" ], raise_on_bad_request: true) }
          .to raise_error(Twitch::HelixClient::BadRequestError, /Bad Identifiers/)
      end
    end
  end

  describe "token management" do
    it "caches token in Redis" do
      # First call gets token
      stub_request(:get, "https://api.twitch.tv/helix/users?login=test")
        .to_return(
          status: 200,
          body: { data: [] }.to_json,
          headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "799" }
        )

      client.get_users(logins: [ "test" ])

      # Token endpoint should be called once
      expect(WebMock).to have_requested(:post, "https://id.twitch.tv/oauth2/token").once
    end
  end

  describe "rate limit tracking" do
    it "logs warning when remaining < 50" do
      stub_request(:get, "https://api.twitch.tv/helix/users?login=test")
        .to_return(
          status: 200,
          body: { data: [] }.to_json,
          headers: { "Content-Type" => "application/json", "Ratelimit-Remaining" => "30" }
        )

      expect(Rails.logger).to receive(:warn).with(/rate limit low: 30/)
      client.get_users(logins: [ "test" ])
    end
  end
end
