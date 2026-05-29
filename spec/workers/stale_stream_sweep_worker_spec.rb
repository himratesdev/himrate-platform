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
    it "skips and warns when channel has no twitch_id" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      channel.update_columns(twitch_id: nil)

      expect(StreamOfflineWorker).not_to receive(:perform_async)
      expect(Rails.logger).to receive(:warn).with(/missing twitch_id\/login/)
      worker.perform
    end
  end
end
