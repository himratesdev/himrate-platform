# frozen_string_literal: true

require "rails_helper"

RSpec.describe StaleStreamSweepWorker do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "ssw1", login: "ssw_chan") }

  before do
    allow(Flipper).to receive(:enabled?).with(:stale_stream_sweep).and_return(true)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
  end

  describe "with flag OFF" do
    it "no-ops" do
      allow(Flipper).to receive(:enabled?).with(:stale_stream_sweep).and_return(false)
      stream = create(:stream, channel: channel, started_at: 6.hours.ago, ended_at: nil)

      worker.perform
      expect(stream.reload.ended_at).to be_nil
    end
  end

  describe "stale criteria" do
    it "closes a stream older than MIN_STREAM_AGE with no CCV snapshots" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)

      worker.perform

      stream.reload
      expect(stream.ended_at).to be_present
    end

    it "closes a stream whose latest CCV snapshot is older than STALE_THRESHOLD" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 45.minutes.ago, ccv_count: 100)

      worker.perform

      stream.reload
      expect(stream.ended_at).to be_present
      # ended_at should match the last known CCV timestamp (preserves accuracy of stream window)
      expect(stream.ended_at).to be_within(1.second).of(45.minutes.ago)
    end

    it "does NOT close a stream with recent CCV snapshot" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)
      create(:ccv_snapshot, stream: stream, timestamp: 5.minutes.ago, ccv_count: 100)

      worker.perform

      expect(stream.reload.ended_at).to be_nil
    end

    it "does NOT close a freshly-started stream (younger than MIN_STREAM_AGE)" do
      stream = create(:stream, channel: channel, started_at: 5.minutes.ago, ended_at: nil)

      worker.perform

      expect(stream.reload.ended_at).to be_nil
    end

    it "ignores already-closed streams" do
      stream = create(:stream, channel: channel, started_at: 4.hours.ago, ended_at: 1.hour.ago)
      original_ended = stream.ended_at

      worker.perform

      expect(stream.reload.ended_at.to_i).to eq(original_ended.to_i)
    end
  end

  describe "IRC PART publication" do
    it "publishes a PART command for each closed stream" do
      stream = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)

      redis_spy = instance_double(Redis)
      allow(Redis).to receive(:new).and_return(redis_spy)
      expect(redis_spy).to receive(:publish).with(
        "irc:commands",
        { action: "part", channel_login: channel.login }.to_json
      )

      worker.perform
      expect(stream.reload.ended_at).to be_present
    end

    it "does NOT raise if Redis publish fails (graceful)" do
      create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil)

      redis_spy = instance_double(Redis)
      allow(Redis).to receive(:new).and_return(redis_spy)
      allow(redis_spy).to receive(:publish).and_raise(Redis::ConnectionError.new("down"))

      expect { worker.perform }.not_to raise_error
    end
  end
end
