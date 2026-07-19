# frozen_string_literal: true

require "rails_helper"

RSpec.describe Calibration::Registry do
  it "loads illustrative defaults when nothing is seeded (half-seeded env degrades, not crashes)" do
    k = described_class.load
    expect(k.pi0).to eq(0.02)
    expect(k.tau_hard).to eq(0.90)
    expect(k.phi_yellow).to eq(0.10)
    expect(k.phi_red).to eq(0.35)
    expect(k.llr_known_bot).to eq(3.40)
  end

  it "overrides a default with the stored (GATE-0-calibrated) value" do
    CalibrationConstant.create!(key: "phi_red", value: 0.42, source: "gate0_holdout", calibrated: true)
    CalibrationConstant.create!(key: "tau_hard", value: 0.95)
    k = described_class.load
    expect(k.phi_red).to eq(0.42)
    expect(k.tau_hard).to eq(0.95)
    expect(k.phi_yellow).to eq(0.10) # untouched key keeps its illustrative default
  end

  it "exposes exactly the keys the L0→L4 engine reads" do
    expect(described_class::K.members).to contain_exactly(
      :pi0, :tau_hard, :tau_delta, :phi_yellow, :phi_red, :q_mid, :q_hi,
      :llr_temporal_r2, :llr_temporal_r3, :llr_temporal_r4, :llr_temporal_r7,
      :llr_per_user_bot_score, :llr_known_bot
    )
  end
end
