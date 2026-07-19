# frozen_string_literal: true

require "rails_helper"

# T1-074 (TI v2) — CalibrationConstant: flat configurable engine thresholds (illustrative until GATE 0).
RSpec.describe CalibrationConstant do
  it "validates presence + uniqueness of key, numeric value, and presence of source" do
    CalibrationConstant.create!(key: "phi_yellow", value: 0.10)
    expect(CalibrationConstant.new(key: "phi_yellow", value: 0.11)).not_to be_valid # dup key
    expect(CalibrationConstant.new(key: "phi_red", value: "nope")).not_to be_valid   # non-numeric
    expect(CalibrationConstant.new(value: 0.1)).not_to be_valid                       # missing key
  end

  it "defaults source to 'illustrative' and calibrated to false (pre-GATE 0)" do
    c = CalibrationConstant.create!(key: "tau_hard", value: 0.9)
    expect(c.source).to eq("illustrative")
    expect(c.calibrated).to be(false)
  end

  describe ".value_for" do
    before { CalibrationConstant.create!(key: "phi_red", value: 0.35) }

    it "returns the value by key, else the supplied fallback, else nil" do
      expect(CalibrationConstant.value_for("phi_red")).to eq(0.35)
      expect(CalibrationConstant.value_for("q_mid", fallback: 0.5)).to eq(0.5)
      expect(CalibrationConstant.value_for("q_mid")).to be_nil
    end
  end
end
