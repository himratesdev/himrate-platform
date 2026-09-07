# frozen_string_literal: true

require "rails_helper"

# The harvester's value AND its risk are both in the attribution rules: a link in a channel's chat
# often belongs to someone else (shared chat, viewer self-promo, announce-bots quoting other
# channels). These specs pin exactly which evidence is enough.
RSpec.describe Social::ChatLinkHarvesterWorker do
  let!(:channel) { create(:channel, login: "dear_hellgirl") }
  let(:ch) { instance_double(Clickhouse::Client) }

  before { allow(Clickhouse::Client).to receive(:new).and_return(ch) }

  def row(url, days: 1, posters: 1, insider: 0, login: "dear_hellgirl")
    { "channel_login" => login, "url" => url, "days" => days.to_s,
      "posters" => posters.to_s, "by_insider" => insider.to_s, "mentions" => "5" }
  end

  it "accepts a link posted by a moderator or the broadcaster" do
    allow(ch).to receive(:select).and_return([ row("https://t.me/SomeOtherName", insider: 1) ])

    described_class.new.perform

    link = channel.reload.social_links.find_by(platform: "telegram")
    expect(link.handle).to eq("SomeOtherName")
    expect(link.source).to eq("chat")
  end

  it "accepts a handle that looks like the channel even from a plain viewer" do
    allow(ch).to receive(:select).and_return([ row("https://t.me/DearHellGirl") ])

    described_class.new.perform

    expect(channel.reload.social_links.pluck(:handle)).to eq([ "DearHellGirl" ])
  end

  it "accepts a standing announcement (several days, several posters)" do
    allow(ch).to receive(:select).and_return([ row("https://t.me/our_cosy_chat", days: 4, posters: 3) ])

    described_class.new.perform

    expect(channel.reload.social_links.pluck(:handle)).to eq([ "our_cosy_chat" ])
  end

  it "rejects a one-off stranger link (the shared-chat / self-promo case)" do
    allow(ch).to receive(:select).and_return([ row("https://t.me/sledovatel_game", days: 1, posters: 1) ])

    described_class.new.perform

    expect(channel.reload.social_links).to be_empty
  end

  it "never overwrites a link the streamer declared on Twitch" do
    declared = ChannelSocialLink.create!(channel: channel, platform: "telegram", handle: "declared",
                                         url: "https://t.me/declared", source: "twitch_panel")
    allow(ch).to receive(:select).and_return([ row("https://t.me/declared", insider: 1) ])

    described_class.new.perform

    expect(declared.reload.source).to eq("twitch_panel")
    expect(declared.handle).to eq("declared")
  end

  it "ignores hosts outside the named taxonomy (no more 'oxygendonuts' platforms)" do
    allow(ch).to receive(:select).and_return([ row("https://oxygendonuts.com/promo", insider: 1) ])

    described_class.new.perform

    expect(channel.reload.social_links).to be_empty
  end

  it "degrades quietly when ClickHouse is unavailable" do
    allow(ch).to receive(:select).and_raise(Clickhouse::QueryError, "down")

    expect { described_class.new.perform }.not_to raise_error
  end
end
