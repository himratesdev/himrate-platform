# frozen_string_literal: true

require "rails_helper"

# WS2: the 60s poll defers CCV writes to the Hermes realtime ingest for streams it already covers.
RSpec.describe StreamMonitorWorker, "#hermes_covered_stream_ids" do
  let(:worker) { described_class.new }
  let(:channel) { create(:channel, twitch_id: "12345", login: "teststreamer") }
  let(:stream) { create(:stream, channel: channel, ended_at: nil) }
  let(:batch) { [ stream ] }

  context "when :hermes_monitor is OFF (prod default)" do
    before { allow(Flipper).to receive(:enabled?).with(:hermes_monitor).and_return(false) }

    it "returns an empty set without querying snapshots (short-circuits)" do
      expect(CcvSnapshot).not_to receive(:where)
      expect(worker.send(:hermes_covered_stream_ids, batch)).to eq(Set.new)
    end
  end

  context "when :hermes_monitor is ON" do
    before { allow(Flipper).to receive(:enabled?).with(:hermes_monitor).and_return(true) }

    it "includes a stream with a snapshot inside the fresh window (Hermes owns CCV)" do
      create(:ccv_snapshot, stream: stream, timestamp: 20.seconds.ago)
      expect(worker.send(:hermes_covered_stream_ids, batch)).to include(stream.id)
    end

    it "excludes a stream whose newest snapshot is stale (poll writes as fallback)" do
      create(:ccv_snapshot, stream: stream, timestamp: 90.seconds.ago)
      expect(worker.send(:hermes_covered_stream_ids, batch)).not_to include(stream.id)
    end

    it "excludes a stream with no snapshots yet" do
      expect(worker.send(:hermes_covered_stream_ids, batch)).not_to include(stream.id)
    end
  end
end
