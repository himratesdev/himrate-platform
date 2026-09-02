# frozen_string_literal: true

require "rails_helper"

RSpec.describe PostStreamNotificationService do
  let(:channel) { create(:channel) }
  # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): duration_ms column dropped from streams —
  # canonical home is post_stream_reports.duration_ms (PSR row provides duration to
  # PostStreamNotificationService via Stream#current_duration_ms).
  let(:stream) { create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago) }

  describe ".broadcast_stream_ended" do
    # Legacy v1 payload (ti_score / erv_percent). ti_v2_engine lives in ALL_FLAGS, so rails_helper
    # enables it for every example — the stance is explicit here; the v2 payload the extension
    # actually consumes today has its own describe below.
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(false)
    end

    let(:report) do
      create(:post_stream_report, stream: stream,
        trust_index_final: 72.0, erv_percent_final: 72.0, duration_ms: 7_200_000)
    end

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
  # PR3b (T1-074, C1): the production payload — {erv, erv_interval, band, engine_version} with
  # ti_score / erv_percent retired. This is what the extension's stream_ended handler reads.
  describe ".broadcast_stream_ended under ti_v2_engine" do
    before do
      allow(Flipper).to receive(:enabled?).and_call_original
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
    end

    let(:report) { create(:post_stream_report, stream: stream, erv_final: 3200, duration_ms: 7_200_000) }
    let(:tih) do
      TrustIndexHistory.create!(channel: channel, stream: stream, engine_version: "v2",
                                authenticity: 82.0, erv: 3200, erv_lo: 3000, erv_hi: 3400,
                                band_row: 2, band_color: "green", cold_start_tier: "full",
                                calculated_at: 5.minutes.ago)
    end

    it "sends the v2 shape (erv + interval + canonical band) and no retired scalars" do
      expect(TrustChannel).to receive(:broadcast_to) do |_ch, payload|
        expect(payload[:erv]).to eq(3200)
        expect(payload[:erv_interval]).to eq({ lo: 3000, hi: 3400 })
        expect(payload[:band]).to include(row: 2, color: "green", sub: nil)
        expect(payload[:band][:label_key]).to be_present
        expect(payload[:engine_version]).to eq("v2")
        expect(payload).not_to have_key(:ti_score)
        expect(payload).not_to have_key(:erv_percent)
      end

      described_class.broadcast_stream_ended(stream, report, tih: tih)
    end

    it "falls back to the grey band shape (never nil) when no v2 TIH row is available" do
      expect(TrustChannel).to receive(:broadcast_to) do |_ch, payload|
        expect(payload[:band]).to eq({ row: 5, color: "grey", label_key: "band.grey_insufficient", sub: nil })
        expect(payload[:erv_interval]).to be_nil
      end

      described_class.broadcast_stream_ended(stream, report, tih: nil)
    end
  end
end
