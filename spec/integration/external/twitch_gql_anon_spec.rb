# frozen_string_literal: true

# External-integration lane (4.3): REAL Twitch GQL, keyless (Android Client-ID baked into the
# client — the Kasada-free path the whole ingest depends on). No credentials required.
require "rails_helper"
require_relative "live_channel_helper"

RSpec.describe "Twitch GQL anonymous (real API)", :external, type: :integration do
  let(:client) { Twitch::GqlClient.new }

  it "bot_check resolves the canonical 'twitch' account" do
    profile = client.bot_check(login: "twitch")
    expect(profile).to be_a(Hash)
    expect(profile[:id].to_s).to eq("12826")
  end

  it "community_tab returns a chatters roster for a live channel" do
    login = ExternalLiveChannel.pick
    skip "no live channel resolvable (Helix creds absent and fallbacks offline)" if login.nil?

    tab = client.community_tab(channel_login: login)
    skip "#{login} went offline mid-test" if tab.nil?
    expect(tab[:total_present]).to be_a(Integer)
    expect(tab[:all_logins]).to be_an(Array)
  end
end
