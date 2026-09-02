# frozen_string_literal: true

# External-integration lane (4.3): REAL Twitch Helix. Needs TWITCH_CLIENT_ID/SECRET
# (app-token flow via id.twitch.tv). Run: EXTERNAL_INTEGRATION=1 bundle exec rspec spec/integration/external
require "rails_helper"

RSpec.describe "Twitch Helix (real API)", :external, type: :integration do
  before do
    skip "TWITCH_CLIENT_ID/SECRET not set" if ENV["TWITCH_CLIENT_ID"].blank? || ENV["TWITCH_CLIENT_SECRET"].blank? ||
                                              ENV["TWITCH_CLIENT_ID"] == "test_client_id"
  end

  let(:client) { Twitch::HelixClient.new }

  it "resolves the canonical 'twitch' account via /users" do
    users = client.get_users(logins: [ "twitch" ])
    expect(users).to be_an(Array)
    expect(users.first).to include("id" => "12826", "login" => "twitch")
  end

  it "returns at least one live stream via /streams" do
    streams = client.get_streams(first: 1)
    expect(streams).to be_an(Array)
    expect(streams.size).to be >= 1
    expect(streams.first).to include("user_login")
    expect(streams.first["viewer_count"]).to be_a(Integer)
  end
end
