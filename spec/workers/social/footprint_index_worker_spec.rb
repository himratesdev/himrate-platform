# frozen_string_literal: true

require "rails_helper"

RSpec.describe Social::FootprintIndexWorker do
  let(:channel) { create(:channel, login: "recrent", is_monitored: true, social_synced_at: nil) }

  before { allow(Flipper).to receive(:enabled?).with(:social_footprint_index).and_return(true) }

  # The worker batches channel_about (one GQL request per slice) then normalizes each slot via
  # TwitchSocials.from_about. Stub the batch to hand back a per-login sentinel `about`, and from_about
  # to map that sentinel → the desired socials/nil. mapping: { login => socials-array | [] | nil }.
  def stub_footprint(mapping)
    allow_any_instance_of(Twitch::GqlClient).to receive(:batch_channel_about) do |_client, logins:|
      logins.to_h { |l| [ l, { login: l } ] }
    end
    allow(SocialAnalytics::TwitchSocials).to receive(:from_about) { |about| about && mapping[about[:login]] }
  end

  it "no-ops when the flag is off (no GQL)" do
    allow(Flipper).to receive(:enabled?).with(:social_footprint_index).and_return(false)
    expect_any_instance_of(Twitch::GqlClient).not_to receive(:batch_channel_about)
    described_class.new.perform
  end

  it "indexes a channel's footprint and stamps social_synced_at" do
    channel
    stub_footprint("recrent" => [
      { platform: "telegram", title: "Telegram", url: "https://t.me/recrent", handle: "recrent", analyzable: true },
      { platform: "discord", title: "Discord", url: "https://discord.gg/recrent", handle: nil, analyzable: false }
    ])

    described_class.new.perform

    links = channel.social_links.reload
    expect(links.map(&:platform)).to contain_exactly("telegram", "discord")
    expect(links.analyzable.map(&:platform)).to eq([ "telegram" ])
    expect(channel.reload.social_synced_at).to be_present
  end

  it "replaces the link set on a re-sync (removed links disappear)" do
    channel.update!(social_synced_at: 8.days.ago)
    channel.social_links.create!(platform: "vk", url: "https://vk.com/old", analyzable: true)
    stub_footprint("recrent" => [
      { platform: "telegram", title: "Telegram", url: "https://t.me/recrent", handle: "recrent", analyzable: true }
    ])

    described_class.new.perform

    expect(channel.social_links.reload.map(&:url)).to eq([ "https://t.me/recrent" ])
  end

  it "stamps (0 links) when the channel genuinely has no socials (`[]`)" do
    channel
    stub_footprint("recrent" => [])

    described_class.new.perform

    expect(channel.social_links.reload).to be_empty
    expect(channel.reload.social_synced_at).to be_present
  end

  it "does NOT stamp on a partial socialMedias-field failure (from_about → nil) so it retries" do
    channel
    stub_footprint("recrent" => nil)

    described_class.new.perform

    expect(channel.reload.social_synced_at).to be_nil
  end

  it "does NOT stamp on a transient batch-slot failure (nil result) so it retries" do
    channel
    allow_any_instance_of(Twitch::GqlClient).to receive(:batch_channel_about).and_return("recrent" => nil)

    described_class.new.perform

    expect(channel.reload.social_synced_at).to be_nil
  end

  it "STAMPS a dead channel (:not_found — 200 but user null) empty so it stops churning the queue" do
    channel
    allow_any_instance_of(Twitch::GqlClient).to receive(:batch_channel_about).and_return("recrent" => :not_found)

    described_class.new.perform

    expect(channel.social_links.reload).to be_empty
    expect(channel.reload.social_synced_at).to be_present # stamped → drops out of NULLS-FIRST head
  end

  it "dedupes a duplicate URL from Twitch (unique index would otherwise abort the channel)" do
    channel
    stub_footprint("recrent" => [
      { platform: "youtube", title: "YT", url: "https://youtube.com/c/x", handle: "x", analyzable: true },
      { platform: "youtube", title: "YT2", url: "https://youtube.com/c/x", handle: "x", analyzable: true }
    ])

    described_class.new.perform

    expect(channel.social_links.reload.count).to eq(1)
  end

  it "picks only stale/never-synced monitored channels, BOUNDED (MAX_PER_RUN) and OLDEST-first" do
    stub_const("#{described_class}::MAX_PER_RUN", 2)
    create(:channel, login: "oldest", is_monitored: true, social_synced_at: 40.days.ago)
    create(:channel, login: "middle", is_monitored: true, social_synced_at: 20.days.ago)
    create(:channel, login: "newest_stale", is_monitored: true, social_synced_at: 8.days.ago)
    fresh = create(:channel, login: "fresh", is_monitored: true, social_synced_at: 1.hour.ago)
    create(:channel, login: "unmon", is_monitored: false, social_synced_at: nil)

    fetched = []
    allow_any_instance_of(Twitch::GqlClient).to receive(:batch_channel_about) do |_c, logins:|
      fetched.concat(logins)
      logins.to_h { |l| [ l, { login: l } ] }
    end
    allow(SocialAnalytics::TwitchSocials).to receive(:from_about).and_return([])

    described_class.new.perform

    # bound = 2 (not 3 eligible); order = oldest first; fresh + unmonitored excluded
    expect(fetched).to eq(%w[oldest middle])
    expect(fresh.reload.social_synced_at).to be_within(2.minutes).of(1.hour.ago)
  end

  it "prefers never-synced (NULL) channels first (NULLS FIRST)" do
    create(:channel, login: "has_stamp", is_monitored: true, social_synced_at: 100.days.ago)
    create(:channel, login: "never", is_monitored: true, social_synced_at: nil)

    fetched = []
    allow_any_instance_of(Twitch::GqlClient).to receive(:batch_channel_about) do |_c, logins:|
      fetched.concat(logins)
      logins.to_h { |l| [ l, { login: l } ] }
    end
    allow(SocialAnalytics::TwitchSocials).to receive(:from_about).and_return([])

    described_class.new.perform

    expect(fetched.first).to eq("never")
  end
end
