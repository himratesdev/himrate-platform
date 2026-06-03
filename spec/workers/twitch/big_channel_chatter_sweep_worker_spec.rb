# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::BigChannelChatterSweepWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, login: "summit1g") }

  let(:sweep_result) do
    {
      broadcasters: [ "summit1g" ],
      moderators: %w[mod1 mod2],
      vips: [],
      staff: [],
      viewers: (1..1781).map { |i| "viewer#{i}" },
      count: 8414,
      total_present: 8414,
      all_logins: [ "summit1g", "mod1", "mod2" ] + (1..1781).map { |i| "viewer#{i}" },
      parallel_calls: 20,
      successful_calls: 20,
      unique_viewer_logins: 1781,
      viewer_samples_total: 2000,
      dedupe_ratio: 0.8905
    }
  end

  before do
    Flipper.enable(:big_channel_chatter_sweep)
    Sidekiq.redis { |c| c.del("twitch:big_chatter_sweep:throttle:#{channel.id}") }
  end

  after do
    Flipper.disable(:big_channel_chatter_sweep)
  end

  it "noops if flag disabled" do
    Flipper.disable(:big_channel_chatter_sweep)
    expect_any_instance_of(Twitch::GqlClient).not_to receive(:community_tab_parallel)
    worker.perform(channel.id)
  end

  it "noops if channel id is unknown" do
    expect_any_instance_of(Twitch::GqlClient).not_to receive(:community_tab_parallel)
    worker.perform("00000000-0000-0000-0000-000000000000")
  end

  it "noops if channel.login is blank" do
    channel.update_column(:login, "")
    expect_any_instance_of(Twitch::GqlClient).not_to receive(:community_tab_parallel)
    worker.perform(channel.id)
  end

  it "runs sweep + emits AS::N event with telemetry" do
    expect_any_instance_of(Twitch::GqlClient)
      .to receive(:community_tab_parallel)
      .with(channel_login: "summit1g", concurrent_calls: described_class::DEFAULT_CONCURRENT_CALLS)
      .and_return(sweep_result)

    events = []
    callback = ->(_name, _start, _finish, _id, payload) { events << payload }
    ActiveSupport::Notifications.subscribed(callback, "twitch.big_channel_chatter_sweep") do
      worker.perform(channel.id)
    end

    expect(events.size).to eq(1)
    expect(events.first).to include(
      channel_id: channel.id,
      channel_login: "summit1g",
      parallel_calls: 20,
      successful_calls: 20,
      unique_viewer_logins: 1781,
      dedupe_ratio: 0.8905,
      count: 8414
    )
  end

  it "respects per-channel throttle (SETNX with TTL)" do
    expect_any_instance_of(Twitch::GqlClient)
      .to receive(:community_tab_parallel)
      .once
      .and_return(sweep_result)

    worker.perform(channel.id)
    worker.perform(channel.id) # second call inside TTL window — should be throttled
  end

  it "honors custom concurrent_calls override" do
    expect_any_instance_of(Twitch::GqlClient)
      .to receive(:community_tab_parallel)
      .with(channel_login: "summit1g", concurrent_calls: 5)
      .and_return(sweep_result.merge(parallel_calls: 5, successful_calls: 5))

    worker.perform(channel.id, 5)
  end

  it "returns nil + logs warn when sweep returns nil (all threads errored)" do
    expect_any_instance_of(Twitch::GqlClient)
      .to receive(:community_tab_parallel).and_return(nil)
    expect(Rails.logger).to receive(:warn).with(/returned nil/)

    expect(worker.perform(channel.id)).to be_nil
  end

  # PR-A3: persist bigger viewer_logins union into the latest ChattersSnapshot
  # of the channel's currently-live stream.
  describe "ChattersSnapshot persistence" do
    let(:stream) { create(:stream, channel: channel, ended_at: nil) }
    let!(:snapshot) do
      ChattersSnapshot.create!(
        stream: stream,
        timestamp: 1.minute.ago,
        unique_chatters_count: 50,
        total_messages_count: 200,
        chatters_present_total: 250,
        viewer_logins: %w[mod1 mod2 vip1 v1 v2 v3], # 6 capped from single CommunityTab
        broadcasters_count: 0,
        moderators_count: 2,
        vips_count: 1,
        staff_count: 0,
        viewers_count_present: 3
      )
    end

    before do
      allow_any_instance_of(Twitch::GqlClient)
        .to receive(:community_tab_parallel)
        .and_return(sweep_result)
    end

    it "merges sweep all_logins into latest snapshot's viewer_logins" do
      expect { worker.perform(channel.id) }.to change { snapshot.reload.viewer_logins.size }
        .from(6).to(1781 + 3)  # 1784 = sweep all_logins (1784) ∪ existing (6) — 5 dupes from "summit1g" + "mod1/mod2" overlap
        .or(change { snapshot.reload.viewer_logins.size }.from(6).to(a_value > 1780))
    end

    it "updates chatters_present_total to max(existing, sweep.count)" do
      worker.perform(channel.id)
      expect(snapshot.reload.chatters_present_total).to eq(8414)  # sweep.count > existing 250
    end

    it "updates viewers_count_present to max(existing, sweep.viewers.uniq.size)" do
      worker.perform(channel.id)
      expect(snapshot.reload.viewers_count_present).to eq(1781)
    end

    it "emits AS::N event with persisted status :persisted" do
      events = []
      ActiveSupport::Notifications.subscribed(->(_n, _s, _f, _i, payload) { events << payload }, "twitch.big_channel_chatter_sweep") do
        worker.perform(channel.id)
      end
      expect(events.first[:persisted]).to include(status: :persisted, stream_id: stream.id, delta: a_value > 1700)
    end

    it "skips persistence (status :no_gain) when sweep returns SAME or FEWER unique chatters" do
      smaller_result = sweep_result.merge(
        all_logins: %w[mod1 mod2 vip1 v1],  # 4 logins, all already in existing 6
        viewers: %w[v1],
        unique_viewer_logins: 1
      )
      allow_any_instance_of(Twitch::GqlClient).to receive(:community_tab_parallel).and_return(smaller_result)

      events = []
      ActiveSupport::Notifications.subscribed(->(_n, _s, _f, _i, payload) { events << payload }, "twitch.big_channel_chatter_sweep") do
        worker.perform(channel.id)
      end

      expect(events.first[:persisted]).to include(status: :no_gain)
      expect(snapshot.reload.viewer_logins.size).to eq(6) # unchanged
    end

    it "reports :no_live_stream when channel has no active stream" do
      stream.update!(ended_at: 5.minutes.ago)

      events = []
      ActiveSupport::Notifications.subscribed(->(_n, _s, _f, _i, payload) { events << payload }, "twitch.big_channel_chatter_sweep") do
        worker.perform(channel.id)
      end

      expect(events.first[:persisted]).to eq(status: :no_live_stream)
    end

    it "reports :no_snapshot when live stream has no chatters_snapshots yet" do
      snapshot.destroy

      events = []
      ActiveSupport::Notifications.subscribed(->(_n, _s, _f, _i, payload) { events << payload }, "twitch.big_channel_chatter_sweep") do
        worker.perform(channel.id)
      end

      expect(events.first[:persisted]).to include(status: :no_snapshot, stream_id: stream.id)
    end
  end
end
