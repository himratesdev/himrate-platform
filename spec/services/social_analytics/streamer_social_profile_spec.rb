# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::StreamerSocialProfile do
  it "assembles the footprint + real Telegram analysis for a streamer" do
    allow(SocialAnalytics::TwitchSocials).to receive(:call).with("recrent").and_return([
      { platform: "telegram", title: "Telegram", url: "https://t.me/recrent", handle: "recrent", analyzable: true },
      { platform: "vk", title: "VK", url: "https://vk.com/recrent", handle: "recrent", analyzable: true }
    ])
    allow(SocialAnalytics::Telegram::PublicProfile).to receive(:call).with("recrent").and_return(
      handle: "recrent", title: "Recrent", subscribers: 236_000,
      posts: [ { views: 70_000, at: "2026-07-08T12:00:00+00:00" } ],
      metrics: { posts_on_page: 20, avg_views: 55_985, view_sub_ratio: 23.7, view_cv: 0.24 }
    )

    r = described_class.call("Recrent")

    expect(r[:login]).to eq("recrent")
    expect(r[:socials].size).to eq(2)                              # full footprint
    tg = r.dig(:platforms, :telegram)
    expect(tg).to include(available: true, subscribers: 236_000)
    expect(tg[:metrics]).to include(view_sub_ratio: 23.7)          # descriptive metric, no fraud verdict
    expect(tg).not_to have_key(:trust)                             # socials = no накрутка score
  end

  it "marks Telegram unavailable when the public preview cannot be read" do
    allow(SocialAnalytics::TwitchSocials).to receive(:call).and_return([
      { platform: "telegram", url: "https://t.me/private_ch", handle: "private_ch", analyzable: true }
    ])
    allow(SocialAnalytics::Telegram::PublicProfile).to receive(:call).and_return(nil)

    tg = described_class.call("x").dig(:platforms, :telegram)
    expect(tg).to include(available: false, handle: "private_ch")
  end

  it "returns an empty footprint for a streamer with no linked socials" do
    allow(SocialAnalytics::TwitchSocials).to receive(:call).and_return([])
    r = described_class.call("nosocials")
    expect(r[:socials]).to eq([])
    expect(r[:platforms]).to eq({})
  end

  it "wires the YouTube platform alongside Telegram" do
    allow(SocialAnalytics::TwitchSocials).to receive(:call).and_return([
      { platform: "youtube", url: "https://www.youtube.com/c/recrentchannel", handle: "recrentchannel", analyzable: true }
    ])
    allow(SocialAnalytics::Telegram::PublicProfile).to receive(:call).and_return(nil)
    allow(SocialAnalytics::Youtube::PublicProfile).to receive(:call).with("https://www.youtube.com/c/recrentchannel").and_return(
      title: "Recrent Shorts", subscribers: 55_900, total_views: 65_762_244, video_count: 828,
      metrics: { avg_views: 145_639, er_percent: 2.76 }
    )

    yt = described_class.call("recrent").dig(:platforms, :youtube)
    expect(yt).to include(available: true, subscribers: 55_900, total_views: 65_762_244, video_count: 828)
    expect(yt[:metrics][:er_percent]).to eq(2.76)
  end

  it "degrades gracefully when an external source raises (never crashes the warm)" do
    allow(SocialAnalytics::TwitchSocials).to receive(:call).and_return([
      { platform: "telegram", url: "https://t.me/x", handle: "x", analyzable: true }
    ])
    allow(SocialAnalytics::Telegram::PublicProfile).to receive(:call).and_raise(SocketError, "getaddrinfo: t.me unreachable")

    r = described_class.call("recrent")

    expect(r[:login]).to eq("recrent")           # profile still assembles
    expect(r[:socials].size).to eq(1)            # footprint intact
    expect(r.dig(:platforms, :telegram, :available)).to be(false) # platform marked unavailable, no raise
  end

  it "returns an empty footprint (not a crash) when the Twitch seed itself raises" do
    allow(SocialAnalytics::TwitchSocials).to receive(:call).and_raise(StandardError, "gql down")
    r = described_class.call("recrent")
    expect(r[:socials]).to eq([])
    expect(r[:platforms]).to eq({})
  end
end
