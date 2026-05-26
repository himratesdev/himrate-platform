# frozen_string_literal: true

require "rails_helper"

RSpec.describe FollowerSnapshotWorker do
  let(:worker) { described_class.new }
  let(:helix) { instance_double(Twitch::HelixClient) }

  before do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(true)
    allow(Flipper).to receive(:enabled?).with(:follower_snapshot).and_return(true)
    allow(Twitch::HelixClient).to receive(:new).and_return(helix)
  end

  it "skips when Flipper :stream_monitor disabled" do
    allow(Flipper).to receive(:enabled?).with(:stream_monitor).and_return(false)
    expect(helix).not_to receive(:get_followers_count)
    worker.perform
  end

  it "skips when Flipper :follower_snapshot disabled" do
    allow(Flipper).to receive(:enabled?).with(:follower_snapshot).and_return(false)
    expect(helix).not_to receive(:get_followers_count)
    worker.perform
  end

  it "snapshots a monitored channel that was never synced" do
    channel = create(:channel, twitch_id: "111", login: "bigstreamer", is_monitored: true)
    channel.update_columns(followers_synced_at: nil)
    allow(helix).to receive(:get_followers_count).with(broadcaster_id: "111").and_return(433_933)

    expect { worker.perform }.to change { FollowerSnapshot.where(channel_id: channel.id).count }.by(1)

    snap = FollowerSnapshot.where(channel_id: channel.id).last
    expect(snap.followers_count).to eq(433_933)
    channel.reload
    expect(channel.followers_total).to eq(433_933)
    expect(channel.followers_synced_at).to be_present
  end

  it "persists a zero count as a valid snapshot (0 is real, not a failure)" do
    channel = create(:channel, twitch_id: "222", is_monitored: true)
    channel.update_columns(followers_synced_at: nil)
    allow(helix).to receive(:get_followers_count).with(broadcaster_id: "222").and_return(0)

    worker.perform

    expect(FollowerSnapshot.where(channel_id: channel.id).count).to eq(1)
    expect(channel.reload.followers_total).to eq(0)
    expect(channel.followers_synced_at).to be_present
  end

  it "skips channels already snapshotted within STALE_AFTER" do
    create(:channel, twitch_id: "333", is_monitored: true).update_columns(followers_synced_at: 1.hour.ago)
    expect(helix).not_to receive(:get_followers_count)
    worker.perform
  end

  it "transient Helix nil → no snapshot and no stamp (retries next run)" do
    channel = create(:channel, twitch_id: "444", is_monitored: true)
    channel.update_columns(followers_synced_at: nil)
    allow(helix).to receive(:get_followers_count).with(broadcaster_id: "444").and_return(nil)

    worker.perform

    expect(FollowerSnapshot.where(channel_id: channel.id).count).to eq(0)
    expect(channel.reload.followers_synced_at).to be_nil
  end

  it "ignores non-monitored and soft-deleted channels" do
    create(:channel, twitch_id: "555", is_monitored: false).update_columns(followers_synced_at: nil)
    create(:channel, twitch_id: "666", is_monitored: true, deleted_at: Time.current).update_columns(followers_synced_at: nil)
    expect(helix).not_to receive(:get_followers_count)
    worker.perform
  end

  it "is bounded by MAX_PER_RUN per run (cron re-runs to finish the backlog)" do
    stub_const("FollowerSnapshotWorker::MAX_PER_RUN", 2)
    3.times { |i| create(:channel, twitch_id: "b#{i}", is_monitored: true).update_columns(followers_synced_at: nil) }
    allow(helix).to receive(:get_followers_count).and_return(100)

    worker.perform

    expect(helix).to have_received(:get_followers_count).exactly(2).times
    expect(FollowerSnapshot.count).to eq(2)
  end

  it "prioritizes never-synced channels (NULLS FIRST) over stale-but-synced ones" do
    stub_const("FollowerSnapshotWorker::MAX_PER_RUN", 1)
    create(:channel, twitch_id: "never", is_monitored: true).update_columns(followers_synced_at: nil)
    create(:channel, twitch_id: "old", is_monitored: true).update_columns(followers_synced_at: 3.days.ago)
    allow(helix).to receive(:get_followers_count).and_return(50)

    worker.perform

    expect(helix).to have_received(:get_followers_count).with(broadcaster_id: "never")
  end
end
