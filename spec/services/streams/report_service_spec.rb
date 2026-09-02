# frozen_string_literal: true

require "rails_helper"

# Created 2026-06-01 for BUG-TI-SIGNAL-BREAKDOWN regression coverage; reshaped for
# V1-RETIRE (2026-09-02): the v1 signal_breakdown → signals array derivation is retired —
# `signals` is ALWAYS [] (reason_codes inside the trust_index block replace it) and the
# trust_index block always carries the v2 verdict {erv, erv_interval, authenticity, band,
# confirmed_anomaly, cold_start_tier, confidence_marker, reason_codes, engine_version}.

RSpec.describe Streams::ReportService do
  let(:channel) { create(:channel) }
  # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv / duration_ms columns
  # dropped from streams. Stats home is post_stream_reports.
  let(:stream) do
    s = create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago,
                        game_name: "Just Chatting")
    # NB: this lookup branch tests build_assembled (no PSR) — PSR explicitly NOT created
    # here so #call routes to the assembled-from-TIH path. Live stats derive from
    # CcvSnapshot fallback via Stream#current_*.
    create(:ccv_snapshot, stream: s, timestamp: 2.5.hours.ago, ccv_count: 5000)
    create(:ccv_snapshot, stream: s, timestamp: 2.hours.ago, ccv_count: 3000)
    create(:ccv_snapshot, stream: s, timestamp: 1.5.hours.ago, ccv_count: 4000)
    s
  end

  describe "#call (assembled, no PostStreamReport)" do
    # Forces the build_assembled branch — the trust_index block reads the final v2 TIH directly.
    before do
      create(:trust_index_history,
        channel: channel,
        stream: stream,
        signal_breakdown: {
          "auth_ratio" => { "value" => 0.05, "weight" => 0.21, "confidence" => 1.0, "contribution" => 0.0105 }
        },
        calculated_at: 1.minute.ago)
    end

    it "always returns signals: [] (v1 signal_breakdown derivation retired) even when the JSON column is populated" do
      result = described_class.new(stream: stream, channel: channel).call

      expect(result[:signals]).to eq([])
    end

    it "assembles the v2 trust_index block from the final v2 TIH" do
      result = described_class.new(stream: stream, channel: channel).call

      ti = result[:trust_index]
      expect(ti[:erv]).to eq(3600)
      expect(ti[:erv_interval]).to eq(lo: 3400, hi: 3800)
      expect(ti[:authenticity]).to eq(72.0)
      expect(ti[:band]).to eq(row: 4, color: "green", label_key: "band.green_no_anomaly", sub: nil)
      expect(ti[:confirmed_anomaly]).to be(false)
      expect(ti[:cold_start_tier]).to eq("full")
      expect(ti[:confidence_marker]).to eq("reliable")
      expect(ti[:reason_codes]).to eq([])
      expect(ti[:engine_version]).to eq("v2")
    end

    it "returns signals: [] and trust_index: nil when stream has no TIH (graceful degrade)" do
      stream_without_tih = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 30.minutes.ago)
      result = described_class.new(stream: stream_without_tih, channel: channel).call

      expect(result[:signals]).to eq([])
      expect(result[:trust_index]).to be_nil
    end
  end
end
