# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonitoredLiveDetectorWorker do
  let(:worker) { described_class.new }
  let(:helix) { instance_double(Twitch::HelixClient) }
  let(:redis) { instance_double(Redis) }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
    allow(Redis).to receive(:new).and_return(redis)
    allow(redis).to receive(:incr).and_return(1)
    allow(redis).to receive(:del)
  end

  def live_stream(user_id:, login:, started_at: "2026-05-25T10:00:00Z", ccv: 5000)
    { "user_id" => user_id, "user_login" => login, "started_at" => started_at, "viewer_count" => ccv }
  end

  it "skips entirely when Flipper :stream_monitor is disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect(helix).not_to receive(:get_streams)
    expect(StreamOnlineWorker).not_to receive(:perform_async)

    worker.perform
  end

  it "opens a Stream (via StreamOnlineWorker) for a live monitored channel with no active stream" do
    create(:channel, twitch_id: "111", login: "bigstreamer", is_monitored: true)
    allow(helix).to receive(:get_streams).and_return([ live_stream(user_id: "111", login: "BigStreamer") ])

    expect(StreamOnlineWorker).to receive(:perform_async).with(
      "broadcaster_user_id" => "111",
      "broadcaster_user_login" => "bigstreamer",
      "started_at" => "2026-05-25T10:00:00Z"
    )

    worker.perform
  end

  it "does not re-open a channel that already has an active stream (idempotent)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil)
    allow(helix).to receive(:get_streams).and_return([ live_stream(user_id: "111", login: "big") ])

    expect(StreamOnlineWorker).not_to receive(:perform_async)
    expect(StreamOfflineWorker).not_to receive(:perform_async)

    worker.perform
  end

  it "resets the offline-miss counter when an active channel is still live" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil)
    allow(helix).to receive(:get_streams).and_return([ live_stream(user_id: "111", login: "big") ])

    expect(redis).to receive(:del).with("live_detector:offline_misses:#{channel.id}")
    expect(StreamOfflineWorker).not_to receive(:perform_async)

    worker.perform
  end

  it "closes a Stream only after OFFLINE_MISS_THRESHOLD consecutive misses (debounce)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil)
    allow(helix).to receive(:get_streams).and_return([]) # channel no longer live
    allow(redis).to receive(:incr).and_return(1, 2, 3)   # consecutive cycles

    expect(StreamOfflineWorker).to receive(:perform_async).once.with(
      { "broadcaster_user_id" => "111", "broadcaster_user_login" => "big" },
      "live_detector"
    )

    3.times { worker.perform }
  end

  it "does NOT close streams when every Helix batch fails (no data != offline)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil)
    allow(helix).to receive(:get_streams).and_return(nil) # total Helix failure
    allow(redis).to receive(:incr).and_return(99) # would otherwise trip the threshold

    expect(StreamOfflineWorker).not_to receive(:perform_async)
    expect(StreamOnlineWorker).not_to receive(:perform_async)

    worker.perform
  end

  it "ignores non-monitored channels (no monitored set → no Helix call)" do
    create(:channel, twitch_id: "111", login: "unmonitored", is_monitored: false)
    expect(helix).not_to receive(:get_streams)
    expect(StreamOnlineWorker).not_to receive(:perform_async)

    worker.perform
  end
end
