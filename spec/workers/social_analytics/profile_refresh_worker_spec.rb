# frozen_string_literal: true

require "rails_helper"

RSpec.describe SocialAnalytics::ProfileRefreshWorker do
  let(:login) { "recrent" }

  before do
    Rails.cache.delete(described_class.cache_key(login))
    Rails.cache.delete(described_class.pending_key(login))
    allow(SocialAnalytics::StreamerSocialProfile).to receive(:call).with(login).and_return(
      login: login,
      socials: [ { platform: "telegram", handle: "recrent", analyzable: true } ],
      platforms: { telegram: { handle: "recrent", available: true, subscribers: 236_000,
                               metrics: { avg_views: 56_000, view_sub_ratio: 23.8, posts_on_page: 20 } } }
    )
  end

  it "persists a snapshot per available platform and caches the profile" do
    expect { described_class.new.perform(login) }.to change(SocialProfileSnapshot, :count).by(1)

    snap = SocialProfileSnapshot.for_login(login).on_platform("telegram").last
    expect(snap.subscribers).to eq(236_000)
    expect(snap.view_sub_ratio).to eq(23.8)

    cached = Rails.cache.read(described_class.cache_key(login))
    expect(cached.dig(:platforms, :telegram, :available)).to be(true)
    expect(cached[:generated_at]).to be_present
  end

  it "computes subscriber growth from prior snapshots" do
    SocialProfileSnapshot.create!(twitch_login: login, platform: "telegram",
                                  captured_at: 40.days.ago, subscribers: 200_000, metrics: {})
    described_class.new.perform(login)

    growth = Rails.cache.read(described_class.cache_key(login)).dig(:platforms, :telegram, :growth)
    expect(growth["30d"][:delta]).to eq(36_000)      # 236000 − 200000
    expect(growth["30d"][:pct]).to eq(18.0)
    expect(growth).not_to have_key("365d")           # no datapoint that far back → honestly omitted
  end

  it "clears the pending marker even mid-run" do
    Rails.cache.write(described_class.pending_key(login), true)
    described_class.new.perform(login)
    expect(Rails.cache.exist?(described_class.pending_key(login))).to be(false)
  end
end
