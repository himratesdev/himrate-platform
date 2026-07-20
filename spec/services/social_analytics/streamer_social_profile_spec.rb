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
    expect(tg[:trust][:band_label]).to eq("Аудитория реальная")   # real analysis wired through
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
end
