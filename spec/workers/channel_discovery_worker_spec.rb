# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelDiscoveryWorker do
  let(:worker) { described_class.new }
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    allow(helix).to receive(:get_users).and_return([]) # default: no candidates resolved

    eventsub = instance_double(Twitch::EventSubService)
    allow(Twitch::EventSubService).to receive(:new).and_return(eventsub)
    allow(eventsub).to receive(:subscribe).and_return([ { "id" => "sub-1" } ])
  end

  def stream(id:, login:, viewers:)
    { "user_id" => id, "user_login" => login, "viewer_count" => viewers }
  end

  def helix_user(id:, login: "login", type: "affiliate")
    {
      "id" => id, "login" => login, "display_name" => login.capitalize,
      "broadcaster_type" => type, "description" => "bio",
      "profile_image_url" => "https://cdn.twitch/#{login}.png"
    }
  end

  it "scans the top RU streams (language=ru, first=100)" do
    allow(helix).to receive(:get_streams).with(language: "ru", first: 100).and_return([])

    worker.perform

    expect(helix).to have_received(:get_streams).with(language: "ru", first: 100)
  end

  # TASK-251.13: monetized (affiliate/partner) RU streamer over the viewer floor → monitored, with
  # metadata filled at creation; is_pinned stays false (discovery = broad side, not curated).
  it "creates a monitored channel for an affiliate/partner stream >=300 viewers, metadata filled" do
    allow(helix).to receive(:get_streams).and_return([ stream(id: "111", login: "bigstreamer", viewers: 5000) ])
    allow(helix).to receive(:get_users).with(ids: [ "111" ]).and_return([ helix_user(id: "111", login: "bigstreamer", type: "partner") ])

    expect { worker.perform }.to change(Channel, :count).by(1)

    channel = Channel.find_by(twitch_id: "111")
    expect(channel).to have_attributes(login: "bigstreamer", is_monitored: true, is_pinned: false, broadcaster_type: "partner", display_name: "Bigstreamer")
    expect(channel.metadata_synced_at).to be_present
  end

  it "skips streams below MIN_VIEWERS (300) — never looked up for broadcaster_type" do
    allow(helix).to receive(:get_streams).and_return([ stream(id: "222", login: "smallstreamer", viewers: 250) ])

    expect { worker.perform }.not_to change(Channel, :count)
    expect(helix).not_to have_received(:get_users).with(ids: [ "222" ])
  end

  # PO tier: a non-monetized "regular" streamer (e.g. a pro who never enabled affiliate but streams
  # a lot, like an esports player) qualifies at the higher 500-viewer floor.
  it "admits a non-monetized streamer at >=500 viewers (higher tier floor)" do
    allow(helix).to receive(:get_streams).and_return([ stream(id: "333", login: "esportspro", viewers: 2847) ])
    allow(helix).to receive(:get_users).with(ids: [ "333" ]).and_return([ helix_user(id: "333", login: "esportspro", type: "") ])

    expect { worker.perform }.to change(Channel, :count).by(1)
    expect(Channel.find_by(twitch_id: "333")).to have_attributes(is_monitored: true, is_pinned: false, broadcaster_type: "")
  end

  it "skips a non-monetized streamer between 300 and 500 viewers (below the higher floor)" do
    allow(helix).to receive(:get_streams).and_return([ stream(id: "334", login: "midnone", viewers: 400) ])
    allow(helix).to receive(:get_users).with(ids: [ "334" ]).and_return([ helix_user(id: "334", login: "midnone", type: "") ])

    expect { worker.perform }.not_to change(Channel, :count)
  end

  it "admits a monetized (affiliate) streamer at the lower 300 floor" do
    allow(helix).to receive(:get_streams).and_return([ stream(id: "335", login: "smallaffil", viewers: 350) ])
    allow(helix).to receive(:get_users).with(ids: [ "335" ]).and_return([ helix_user(id: "335", login: "smallaffil", type: "affiliate") ])

    expect { worker.perform }.to change(Channel, :count).by(1)
  end

  it "skips existing channels (idempotent)" do
    create(:channel, twitch_id: "111", login: "bigstreamer")
    allow(helix).to receive(:get_streams).and_return([ stream(id: "111", login: "bigstreamer", viewers: 5000) ])
    allow(helix).to receive(:get_users).with(ids: [ "111" ]).and_return([ helix_user(id: "111", login: "bigstreamer") ])

    expect { worker.perform }.not_to change(Channel, :count)
  end

  it "skips a malformed stream entry and still processes the valid ones" do
    allow(helix).to receive(:get_streams).and_return([
      stream(id: nil, login: "broken", viewers: 1000),
      stream(id: "444", login: "goodchannel", viewers: 2000)
    ])
    allow(helix).to receive(:get_users).with(ids: [ "444" ]).and_return([ helix_user(id: "444", login: "goodchannel") ])

    expect { worker.perform }.to change(Channel, :count).by(1)
    expect(Channel.find_by(twitch_id: "444")).to be_present
  end

  it "skips when Flipper disabled (no Helix call)" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect(helix).not_to receive(:get_streams)

    expect { worker.perform }.not_to change(Channel, :count)
  end
end
