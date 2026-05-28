# frozen_string_literal: true

require "rails_helper"

# CR iter-2 N4: regression guard for CR iter-1 S3 fix (Ratelimit-Reset backoff на 429).
RSpec.describe Twitch::HelixUserFollowsClient do
  let(:user) { create(:user) }
  let(:auth_provider) do
    create(:auth_provider, user: user, provider: "twitch", provider_id: "241581609",
      access_token: "token", scopes: %w[user:read:follows])
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_ID").and_return("test_client_id")
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_ID") { "test_client_id" }
  end

  it "raises after exhausted retries on persistent 429" do
    client = described_class.new(auth_provider: auth_provider)
    rate_limited_response = instance_double(HTTP::Response, code: 429, body: "rate limited",
      headers: { "Ratelimit-Reset" => Time.now.to_i.to_s })
    allow(HTTP).to receive_message_chain(:timeout, :headers, :get).and_return(rate_limited_response)
    # Stub sleep so test doesn't actually wait.
    allow(client).to receive(:sleep)

    expect {
      client.followed_channels_pages.to_a
    }.to raise_error(Twitch::HelixUserFollowsClient::Error, /rate-limited/)
  end
end
