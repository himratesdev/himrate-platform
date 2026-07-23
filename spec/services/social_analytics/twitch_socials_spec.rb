# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::TwitchSocials do
  let(:gql) { instance_double(Twitch::GqlClient) }

  before { allow(Twitch::GqlClient).to receive(:new).and_return(gql) }

  it "normalises Twitch socialMedias into platform/handle with analyzable flags" do
    allow(gql).to receive(:channel_about).with(channel_login: "recrent").and_return(
      social_medias: [
        { name: "t",         title: "Telegram", url: "https://t.me/recrent" },
        { name: "vk",        title: "VK",       url: "https://vk.com/recrent" },
        { name: "youtube",   title: "YouTube",  url: "https://www.youtube.com/c/recrentchannel?sub_confirmation=1" },
        { name: "discord",   title: "Discord",  url: "https://discord.gg/recrent" },
        { name: "gosuslugi", title: "РКН",      url: "https://gosuslugi.ru/snet/abc" }
      ]
    )

    result = described_class.call("Recrent")
    by = result.index_by { |s| s[:platform] }

    expect(by["telegram"]).to include(handle: "recrent", analyzable: true)
    expect(by["vk"]).to include(handle: "recrent", analyzable: true)
    expect(by["youtube"]).to include(handle: "recrentchannel", analyzable: true)
    expect(by["discord"]).to include(analyzable: false)         # display-only footprint link
    expect(by["rkn"]).to include(analyzable: false)             # gosuslugi → РКН flag
  end

  it "returns nil when the GQL fetch fails (distinct from «no socials») so callers can retry" do
    allow(gql).to receive(:channel_about).and_return(nil)
    expect(described_class.call("ghost")).to be_nil
  end

  it "returns [] for a channel fetched OK that has no socials" do
    allow(gql).to receive(:channel_about).and_return(social_medias: nil)
    expect(described_class.call("nosocials")).to eq([])

    allow(gql).to receive(:channel_about).and_return(social_medias: [])
    expect(described_class.call("nosocials2")).to eq([])
  end

  it "is empty for blank input without calling Twitch" do
    expect(described_class.call("")).to eq([])
  end
end
