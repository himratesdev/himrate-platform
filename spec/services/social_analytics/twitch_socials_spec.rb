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

  it "returns nil when channel_about fully fails so callers can retry" do
    allow(gql).to receive(:channel_about).and_return(nil)
    expect(described_class.call("ghost")).to be_nil
  end

  it "returns nil on a PARTIAL failure (base channel present but socialMedias null) — retry, don't stamp empty" do
    allow(gql).to receive(:channel_about).and_return(display_name: "X", social_medias: nil)
    expect(described_class.call("partial")).to be_nil
  end

  it "returns [] for a channel fetched OK that genuinely links no socials (empty array)" do
    allow(gql).to receive(:channel_about).and_return(social_medias: [])
    expect(described_class.call("nosocials")).to eq([])
  end

  it "is empty for blank input without calling Twitch" do
    expect(described_class.call("")).to eq([])
  end

  # .from_about is the shared normalizer the BATCH footprint worker reuses on batch_channel_about slots.
  describe ".from_about" do
    it "normalizes socialMedias from an about hash" do
      about = { social_medias: [ { name: "youtube", title: "YT", url: "https://youtube.com/c/x" } ] }
      expect(described_class.from_about(about)).to eq([
        { platform: "youtube", title: "YT", url: "https://youtube.com/c/x", handle: "x", analyzable: true }
      ])
    end

    it "returns nil for a nil about (fetch failed) or a null socialMedias (partial failure)" do
      expect(described_class.from_about(nil)).to be_nil
      expect(described_class.from_about(social_medias: nil)).to be_nil
    end

    it "returns [] for an empty socialMedias (genuinely no socials)" do
      expect(described_class.from_about(social_medias: [])).to eq([])
    end
  end
end
