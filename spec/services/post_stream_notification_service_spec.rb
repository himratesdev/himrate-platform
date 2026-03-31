# frozen_string_literal: true

require "rails_helper"

RSpec.describe PostStreamNotificationService do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago, duration_ms: 7_200_000) }

  describe ".broadcast_stream_ended" do
    let(:report) { create(:post_stream_report, stream: stream, trust_index_final: 72.0, erv_percent_final: 72.0) }

    it "broadcasts stream_ended via TrustChannel" do
      expect(TrustChannel).to receive(:broadcast_to).with(channel, hash_including(
        type: "stream_ended",
        channel_id: channel.id,
        channel_login: channel.login,
        stream_id: stream.id,
        ti_score: 72.0,
        erv_percent: 72.0,
        duration_ms: 7_200_000,
        merged_parts_count: 1
      ))

      described_class.broadcast_stream_ended(stream, report)
    end

    it "includes expires_at (ended_at + 18h)" do
      expect(TrustChannel).to receive(:broadcast_to).with(channel, hash_including(
        expires_at: (stream.ended_at + 18.hours).iso8601
      ))

      described_class.broadcast_stream_ended(stream, report)
    end

    it "handles nil report gracefully" do
      expect(TrustChannel).to receive(:broadcast_to).with(channel, hash_including(
        ti_score: nil,
        erv_percent: nil
      ))

      described_class.broadcast_stream_ended(stream, nil)
    end

    it "does not raise on broadcast failure" do
      allow(TrustChannel).to receive(:broadcast_to).and_raise(StandardError, "cable down")

      expect { described_class.broadcast_stream_ended(stream, report) }.not_to raise_error
    end
  end

  describe ".broadcast_stream_expiring" do
    it "broadcasts stream_expiring via TrustChannel" do
      expect(TrustChannel).to receive(:broadcast_to).with(channel, hash_including(
        type: "stream_expiring",
        channel_id: channel.id,
        stream_id: stream.id
      ))

      described_class.broadcast_stream_expiring(stream)
    end
  end
end
