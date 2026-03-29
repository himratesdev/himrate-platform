# frozen_string_literal: true

require "rails_helper"

RSpec.describe ChannelDiscoveryWorker do
  let(:worker) { described_class.new }
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_ID").and_return("test_id")
    allow(ENV).to receive(:fetch).with("TWITCH_CLIENT_SECRET").and_return("test_secret")
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)

    eventsub = instance_double(Twitch::EventSubService)
    allow(Twitch::EventSubService).to receive(:new).and_return(eventsub)
    allow(eventsub).to receive(:subscribe).and_return([ { "id" => "sub-1" } ])
  end

  # TC-017: New channel discovered
  it "creates Channel for streams with 50+ viewers" do
    allow(helix).to receive(:get_streams).and_return([
      { "user_id" => "111", "user_login" => "bigstreamer", "viewer_count" => 5000 },
      { "user_id" => "222", "user_login" => "smallstreamer", "viewer_count" => 30 }
    ])

    expect { worker.perform }.to change(Channel, :count).by(1)
    expect(Channel.find_by(twitch_id: "111").login).to eq("bigstreamer")
    expect(Channel.find_by(twitch_id: "222")).to be_nil
  end

  # TC-018: Existing channel → skip
  it "skips existing channels (idempotent)" do
    create(:channel, twitch_id: "111", login: "bigstreamer")

    allow(helix).to receive(:get_streams).and_return([
      { "user_id" => "111", "user_login" => "bigstreamer", "viewer_count" => 5000 }
    ])

    expect { worker.perform }.not_to change(Channel, :count)
  end

  it "handles errors per-channel without cascade failure" do
    allow(helix).to receive(:get_streams).and_return([
      { "user_id" => nil, "user_login" => "broken", "viewer_count" => 100 },
      { "user_id" => "333", "user_login" => "goodchannel", "viewer_count" => 200 }
    ])

    expect { worker.perform }.to change(Channel, :count).by(1)
    expect(Channel.find_by(twitch_id: "333")).to be_present
  end

  it "skips when Flipper disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect { worker.perform }.not_to change(Channel, :count)
  end
end
