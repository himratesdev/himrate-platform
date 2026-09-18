# frozen_string_literal: true

require "rails_helper"

# WS2: the 60s poll defers CCV writes to the Hermes realtime ingest when it is covering a stream.
RSpec.describe StreamMonitorWorker, "#hermes_covering?" do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }
  let(:stream) { create(:stream, channel: channel, ended_at: nil) }

  context "when :hermes_monitor is OFF (prod default)" do
    before { allow(Flipper).to receive(:enabled?).with(:hermes_monitor).and_return(false) }

    it "is false and never queries snapshots (short-circuits)" do
      expect(stream).not_to receive(:ccv_snapshots)
      expect(worker.send(:hermes_covering?, stream)).to be(false)
    end
  end

  context "when :hermes_monitor is ON" do
    before { allow(Flipper).to receive(:enabled?).with(:hermes_monitor).and_return(true) }

    it "is true when a snapshot landed within the fresh window (Hermes owns CCV)" do
      create(:ccv_snapshot, stream: stream, timestamp: 20.seconds.ago)
      expect(worker.send(:hermes_covering?, stream)).to be(true)
    end

    it "is false when the newest snapshot is stale (Hermes down/uncovered → poll writes)" do
      create(:ccv_snapshot, stream: stream, timestamp: 90.seconds.ago)
      expect(worker.send(:hermes_covering?, stream)).to be(false)
    end

    it "is false when there are no snapshots yet" do
      expect(worker.send(:hermes_covering?, stream)).to be(false)
    end
  end
end
