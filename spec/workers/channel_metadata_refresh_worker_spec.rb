# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelMetadataRefreshWorker do
  let(:worker) { described_class.new }
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
  end

  def helix_user(id:, display_name: "Display", login: "login", broadcaster_type: "partner")
    {
      "id" => id, "login" => login, "display_name" => display_name,
      "broadcaster_type" => broadcaster_type, "description" => "bio",
      "profile_image_url" => "https://cdn.twitch/#{login}.png"
    }
  end

  it "skips when Flipper :stream_monitor disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect(helix).not_to receive(:get_users)
    worker.perform
  end

  it "fills metadata for a monitored channel that was never synced" do
    channel = create(:channel, twitch_id: "111", login: "bigstreamer", display_name: nil, is_monitored: true)
    channel.update_columns(metadata_synced_at: nil)
    allow(helix).to receive(:get_users).with(ids: [ "111" ]).and_return([ helix_user(id: "111", display_name: "BigStreamer", login: "bigstreamer") ])

    worker.perform

    channel.reload
    expect(channel.display_name).to eq("BigStreamer")
    expect(channel.profile_image_url).to eq("https://cdn.twitch/bigstreamer.png")
    expect(channel.broadcaster_type).to eq("partner")
    expect(channel.metadata_synced_at).to be_present
  end

  it "skips channels already synced within STALE_AFTER" do
    create(:channel, twitch_id: "222", is_monitored: true).update_columns(metadata_synced_at: 1.hour.ago)
    expect(helix).not_to receive(:get_users)
    worker.perform
  end

  it "stamps metadata_synced_at even when Helix returns no user (banned/deleted)" do
    channel = create(:channel, twitch_id: "333", login: "ghost", display_name: nil, is_monitored: true)
    channel.update_columns(metadata_synced_at: nil)
    allow(helix).to receive(:get_users).with(ids: [ "333" ]).and_return([])

    worker.perform

    channel.reload
    expect(channel.metadata_synced_at).to be_present
    expect(channel.display_name).to be_nil
  end

  it "ignores non-monitored channels" do
    create(:channel, twitch_id: "444", is_monitored: false).update_columns(metadata_synced_at: nil)
    expect(helix).not_to receive(:get_users)
    worker.perform
  end

  # CR Must-Fix: transient Helix failure (nil) must NOT stamp metadata_synced_at — otherwise
  # the row is frozen with null metadata for STALE_AFTER (re-introduces the bug being fixed).
  it "does NOT stamp on transient Helix failure (nil) — stays re-eligible next run" do
    channel = create(:channel, twitch_id: "555", login: "ghost2", display_name: nil, is_monitored: true)
    channel.update_columns(metadata_synced_at: nil)
    allow(helix).to receive(:get_users).and_return(nil)

    worker.perform

    channel.reload
    expect(channel.metadata_synced_at).to be_nil
    expect(channel.display_name).to be_nil
  end
end
