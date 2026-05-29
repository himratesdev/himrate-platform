# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaleStreamSweepWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "ssw1", login: "ssw_chan") }

  before do
    allow(Flipper).to receive(:enabled?).with(:stale_stream_sweep).and_return(true)
  end

  describe "with flag OFF" do
    it "no-ops" do
      allow(Flipper).to receive(:enabled?).with(:stale_stream_sweep).and_return(false)
      create(:stream, channel: channel, started_at: 6.hours.ago, ended_at: nil)

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      worker.perform
    end
  end

  describe "stale criteria" do
    it "enqueues StreamOfflineWorker for a stream older than MIN_STREAM_AGE with no CCV" do
      create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)

      expect(StreamOfflineWorker).to receive(:perform_async).with(
        { "broadcaster_user_id" => "ssw1", "broadcaster_user_login" => "ssw_chan" },
        "stale_sweep"
      )

      worker.perform
    end

    it "enqueues offline for a stream whose latest CCV snapshot is older than STALE_THRESHOLD" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 45.minutes.ago, ccv_count: 100)

      expect(StreamOfflineWorker).to receive(:perform_async).with(
        hash_including("broadcaster_user_login" => "ssw_chan"),
        "stale_sweep"
      )

      worker.perform
    end

    it "does NOT enqueue for a stream with recent CCV snapshot" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 5.minutes.ago, ccv_count: 100)

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      worker.perform
    end

    it "does NOT enqueue a freshly-started stream (younger than MIN_STREAM_AGE)" do
      create(:stream, channel: channel, started_at: 5.minutes.ago, ended_at: nil)

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      worker.perform
    end

    it "ignores already-closed streams" do
      create(:stream, channel: channel, started_at: 4.hours.ago, ended_at: 1.hour.ago)

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      worker.perform
    end

    # CR-iter1 SF-2: oldest stale rows must be picked first so backlog drains predictably.
    it "processes the oldest stale streams first (ORDER BY started_at ASC)" do
      channel2 = create(:channel, twitch_id: "ssw2", login: "ssw_chan2")
      # newer first to verify ORDER BY actually prefers the older one
      create(:stream, channel: channel2, started_at: 1.hour.ago, ended_at: nil)
      old_stream = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: nil)

      enqueued = []
      allow(StreamOfflineWorker).to receive(:perform_async) do |payload, _source|
        enqueued << payload["broadcaster_user_login"]
      end

      stub_const("#{described_class}::BATCH_LIMIT", 10)
      worker.perform

      expect(enqueued.first).to eq("ssw_chan") # the older row
      expect(enqueued).to contain_exactly("ssw_chan", "ssw_chan2")
    end
  end

  describe "missing channel guard" do
    # CR-iter2 SF-2: previous spec used `channel.update_columns(twitch_id: nil)` against the
    # NOT NULL column → ActiveRecord::NotNullViolation, not the intended guard hit. Test the
    # real-world surface (channel row dropped post-pluck) via a Channel.where stub that returns
    # [nil, nil] for the pick — same as if Channel.delete had happened between the pluck and
    # the per-candidate iteration.
    it "skips and warns when channel pick returns nil tuple" do
      create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      relation = double("Channel relation")
      allow(Channel).to receive(:where).and_call_original
      allow(Channel).to receive(:where).with(id: channel.id).and_return(relation)
      allow(relation).to receive(:pick).with(:twitch_id, :login).and_return([ nil, nil ])

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      expect(Rails.logger).to receive(:warn).with(/missing twitch_id\/login/)
      worker.perform
    end
  end

  # CR-iter2 SF-1: stale window symmetry — both "no CCV" and "stale CCV" use STALE_THRESHOLD.
  describe "symmetric STALE_THRESHOLD on no-CCV branch" do
    it "does NOT enqueue a no-CCV stream that's between MIN_STREAM_AGE and STALE_THRESHOLD old" do
      # 15 min old (older than MIN_STREAM_AGE=10min but younger than STALE_THRESHOLD=30min).
      create(:stream, channel: channel, started_at: 15.minutes.ago, ended_at: nil)

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      worker.perform
    end

    it "enqueues a no-CCV stream older than STALE_THRESHOLD" do
      create(:stream, channel: channel, started_at: 45.minutes.ago, ended_at: nil)

      expect(StreamOfflineWorker).to receive(:perform_async)
      worker.perform
    end
  end
end
