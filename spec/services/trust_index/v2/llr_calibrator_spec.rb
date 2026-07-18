# frozen_string_literal: true

require "rails_helper"

module LlrCalibratorSpecDoubles
  # Illustrative LLR table (SRS §5.3 / 07.1 §5).
  K = Data.define(:llr_temporal_r2, :llr_temporal_r3, :llr_temporal_r4, :llr_temporal_r7,
                  :llr_per_user_bot_score, :llr_known_bot).new(
                    llr_temporal_r2: 1.1, llr_temporal_r3: 2.2, llr_temporal_r4: 2.9,
                    llr_temporal_r7: 4.6, llr_per_user_bot_score: 3.9, llr_known_bot: 3.4
                  )
  Signals = Data.define(:temporal_recurrence, :known_bot_hit, :per_user_bot_score,
                        :account_profile_llr, :anti_bot_llr)
end

RSpec.describe TrustIndex::V2::LlrCalibrator do
  let(:k) { LlrCalibratorSpecDoubles::K }

  def signals(**over)
    base = { temporal_recurrence: nil, known_bot_hit: false, per_user_bot_score: nil,
             account_profile_llr: 0.0, anti_bot_llr: 0.0 }
    LlrCalibratorSpecDoubles::Signals.new(**base.merge(over))
  end

  it "sums to 0 when every source is silent (neutral — no clean credit)" do
    expect(described_class.sum_llr(signals, k: k)).to eq(0.0)
  end

  it "grades the cross-channel temporal LLR by recurrence R (2/3/4/≥7 buckets)" do
    expect(described_class.sum_llr(signals(temporal_recurrence: 2), k: k)).to eq(1.1)
    expect(described_class.sum_llr(signals(temporal_recurrence: 3), k: k)).to eq(2.2)
    expect(described_class.sum_llr(signals(temporal_recurrence: 5), k: k)).to eq(2.9) # ≥4 bucket
    expect(described_class.sum_llr(signals(temporal_recurrence: 9), k: k)).to eq(4.6) # ≥7 bucket
  end

  it "adds the known-bot denylist and per-user scorer LLRs" do
    s = signals(known_bot_hit: true, per_user_bot_score: 1.0)
    expect(described_class.sum_llr(s, k: k)).to be_within(1e-9).of(3.4 + 3.9)
  end

  it "scales the per-user scorer LLR linearly by its score (illustrative)" do
    expect(described_class.sum_llr(signals(per_user_bot_score: 0.5), k: k)).to be_within(1e-9).of(1.95)
  end

  it "lets anti-bot signals pull the log-odds DOWN (negative LLR)" do
    s = signals(temporal_recurrence: 2, anti_bot_llr: -3.0)
    expect(described_class.sum_llr(s, k: k)).to be_within(1e-9).of(1.1 - 3.0)
  end
end
