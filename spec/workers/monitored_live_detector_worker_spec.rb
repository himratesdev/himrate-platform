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
    allow(redis).to receive(:expire)
    allow(redis).to receive(:del)
  end

  def live_stream(user_id:, login:, started_at: "2026-05-25T10:00:00Z", ccv: 5000, id: "316159655126")
    { "id" => id, "user_id" => user_id, "user_login" => login, "started_at" => started_at, "viewer_count" => ccv }
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

    # BUG-251.40 A2: payload now carries Helix `id` as `stream_id` for downstream worker.
    expect(StreamOnlineWorker).to receive(:perform_async).with(
      "broadcaster_user_id" => "111",
      "broadcaster_user_login" => "bigstreamer",
      "started_at" => "2026-05-25T10:00:00Z",
      "stream_id" => "316159655126"
    )

    worker.perform
  end

  it "does not re-open a channel whose open stream matches Helix `id` (continuation — BUG-251.40 A2)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil, twitch_stream_id: "316159655126")
    allow(helix).to receive(:get_streams).and_return([ live_stream(user_id: "111", login: "big") ])

    expect(StreamOnlineWorker).not_to receive(:perform_async)
    expect(StreamOfflineWorker).not_to receive(:perform_async)

    worker.perform
  end

  # BUG-251.40 A2: open-side identity-aware skip — the fuse-fix path.
  it "RE-OPENS via StreamOnlineWorker when open stream has DIFFERENT twitch_stream_id (fuse)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    # Stale row from yesterday's broadcast.
    create(:stream, channel: channel, ended_at: nil, twitch_stream_id: "999999999999")
    allow(helix).to receive(:get_streams).and_return([ live_stream(user_id: "111", login: "big") ])

    # Detector enqueues OnlineWorker; OnlineWorker handles close+create internally.
    expect(StreamOnlineWorker).to receive(:perform_async).with(
      hash_including("stream_id" => "316159655126")
    )

    worker.perform
  end

  it "RE-OPENS via StreamOnlineWorker when open stream has NULL twitch_stream_id (legacy A1 pre-write)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil, twitch_stream_id: nil)
    allow(helix).to receive(:get_streams).and_return([ live_stream(user_id: "111", login: "big") ])

    expect(StreamOnlineWorker).to receive(:perform_async).with(
      hash_including("stream_id" => "316159655126")
    )

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

  it "does NOT close a Stream before the miss threshold (e.g. after 2 misses)" do
    channel = create(:channel, twitch_id: "111", login: "big", is_monitored: true)
    create(:stream, channel: channel, ended_at: nil)
    allow(helix).to receive(:get_streams).and_return([]) # channel no longer live
    allow(redis).to receive(:incr).and_return(1, 2)      # only two consecutive misses

    expect(StreamOfflineWorker).not_to receive(:perform_async)

    2.times { worker.perform }
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

  # BUG-251.19: regression test. Partial Helix batch failure used to falsely register
  # offline-misses for channels in the failed sub-batch, debouncing them to closed after
  # 3 cycles even when they were live (incident: partner channel nix went ghost). The fix
  # tracks the set of twitch_ids actually queried successfully; close-reconciliation skips
  # un-queried channels entirely.
  it "does NOT increment offline-miss for channels whose Helix sub-batch failed (partial-batch)" do
    stub_const("MonitoredLiveDetectorWorker::HELIX_BATCH_SIZE", 1)

    success_channel = create(:channel, twitch_id: "111", login: "covered", is_monitored: true)
    failed_channel  = create(:channel, twitch_id: "222", login: "ghosted", is_monitored: true)
    create(:stream, channel: success_channel, ended_at: nil) # open stream — both channels look "active" in DB
    create(:stream, channel: failed_channel,  ended_at: nil)

    # Pluck order matters: get_streams is called once per twitch_id (BATCH_SIZE=1). First batch
    # (twitch_id "111") returns a live response; second batch (twitch_id "222") returns nil = failed.
    allow(helix).to receive(:get_streams) do |user_ids:|
      user_ids == [ "111" ] ? [] : nil # both queried, "111" returned empty (live-set empty), "222" failed
    end
    allow(redis).to receive(:incr).and_return(99) # would trip threshold immediately if registered

    # success_channel ("111") IS in queried set + empty live result → register_offline_miss (first miss
    # ever — but allow(redis).to receive(:incr).and_return(99) trips the debounce, so it WILL close).
    expect(StreamOfflineWorker).to receive(:perform_async).once.with(
      { "broadcaster_user_id" => "111", "broadcaster_user_login" => "covered" },
      "live_detector"
    )
    # failed_channel ("222") is NOT in queried set → MUST be skipped (no incr, no close).
    expect(redis).not_to receive(:incr).with("live_detector:offline_misses:#{failed_channel.id}")
    expect(StreamOfflineWorker).not_to receive(:perform_async).with(
      hash_including("broadcaster_user_id" => "222"),
      anything
    )

    worker.perform
  end

  it "logs a partial-failure marker when at least one Helix sub-batch failed" do
    stub_const("MonitoredLiveDetectorWorker::HELIX_BATCH_SIZE", 1)
    create(:channel, twitch_id: "111", login: "covered", is_monitored: true)
    create(:channel, twitch_id: "222", login: "ghosted", is_monitored: true)
    allow(helix).to receive(:get_streams) { |user_ids:| user_ids == [ "111" ] ? [] : nil }

    expect(Rails.logger).to receive(:info).with(/partial: 1 channels in failed Helix sub-batch/)
    worker.perform
  end

  it "ignores non-monitored channels (no monitored set → no Helix call)" do
    create(:channel, twitch_id: "111", login: "unmonitored", is_monitored: false)
    expect(helix).not_to receive(:get_streams)
    expect(StreamOnlineWorker).not_to receive(:perform_async)

    worker.perform
  end
end
