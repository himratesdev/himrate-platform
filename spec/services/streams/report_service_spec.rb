# frozen_string_literal: true

require "rails_helper"

# Created 2026-06-01 for BUG-TI-SIGNAL-BREAKDOWN regression coverage. Prior to this PR,
# Streams::ReportService#signals queried the dead-write `signals` PG table (TiSignal model
# via self.table_name = "signals") and always returned []. The fix reads from
# TrustIndexHistory.signal_breakdown JSON column, the canonical signal storage post
# TrustIndex::Engine refactor. This spec asserts the new code path returns the populated
# signal array (regression guard against re-introduction of the dead-table query).

RSpec.describe Streams::ReportService do
  let(:channel) { create(:channel) }
  let(:stream) do
    create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago,
                    peak_ccv: 5000, avg_ccv: 4000, duration_ms: 7_200_000, game_name: "Just Chatting")
  end

  describe "#call (assembled, no PostStreamReport)" do
    # Forces the build_assembled branch — :signals method is invoked only there
    # (build_from_psr surfaces psr.signals_summary, not ReportService#signals).
    before do
      create(:trust_index_history,
        channel: channel,
        stream: stream,
        trust_index_score: 72.0,
        erv_percent: 72.0,
        ccv: 5000,
        confidence: 0.85,
        classification: "needs_review",
        cold_start_status: "full",
        signal_breakdown: {
          "auth_ratio" => { "value" => 0.05, "weight" => 0.21, "confidence" => 1.0, "contribution" => 0.0105 },
          "chat_behavior" => { "value" => 0.13, "weight" => 0.17, "confidence" => 0.95, "contribution" => 0.0221 },
          "known_bot_match" => { "value" => 0.0, "weight" => 0.14, "confidence" => 1.0, "contribution" => 0.0 }
        },
        calculated_at: 1.minute.ago)
    end

    it "populates signals array from TIH.signal_breakdown JSON column (BUG-TI-SIGNAL-BREAKDOWN regression guard)" do
      result = described_class.new(stream: stream, channel: channel).call

      signals = result[:signals]
      expect(signals).to be_an(Array)
      expect(signals.size).to eq(3)

      auth_ratio = signals.find { |s| s[:type] == "auth_ratio" }
      expect(auth_ratio).to be_present
      expect(auth_ratio[:value]).to eq(0.05)
      expect(auth_ratio[:weight]).to eq(0.21)
      expect(auth_ratio[:confidence]).to eq(1.0)

      chat_behavior = signals.find { |s| s[:type] == "chat_behavior" }
      expect(chat_behavior[:value]).to eq(0.13)

      types = signals.map { |s| s[:type] }
      expect(types).to contain_exactly("auth_ratio", "chat_behavior", "known_bot_match")
    end

    it "returns empty array when stream has no TIH (graceful degrade)" do
      stream_without_tih = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 30.minutes.ago)
      result = described_class.new(stream: stream_without_tih, channel: channel).call

      expect(result[:signals]).to eq([])
    end

    it "returns empty array when TIH signal_breakdown is nil/empty hash" do
      TrustIndexHistory.where(stream: stream).update_all(signal_breakdown: {})
      result = described_class.new(stream: stream, channel: channel).call

      expect(result[:signals]).to eq([])
    end
  end
end
