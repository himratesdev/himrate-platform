# frozen_string_literal: true

require "rails_helper"

# T1-074 (TI v2) — CalibrationConstant: configurable engine thresholds (illustrative until GATE 0).
RSpec.describe CalibrationConstant do
  it "validates presence + uniqueness of param_name scoped to category, and numeric value" do
    CalibrationConstant.create!(param_name: "phi_yellow", category: "default", param_value: 0.10)
    dup = CalibrationConstant.new(param_name: "phi_yellow", category: "default", param_value: 0.11)
    expect(dup).not_to be_valid
    # same name, different category = allowed
    expect(CalibrationConstant.new(param_name: "phi_yellow", category: "esports", param_value: 0.08)).to be_valid
    expect(CalibrationConstant.new(param_name: "phi_yellow", category: "x", param_value: "nope")).not_to be_valid
  end

  describe ".value_for" do
    before do
      CalibrationConstant.create!(param_name: "phi_red", category: "default", param_value: 0.35)
      CalibrationConstant.create!(param_name: "phi_red", category: "esports", param_value: 0.50)
    end

    it "prefers the exact category, falls back to default, then to the supplied fallback" do
      expect(CalibrationConstant.value_for("phi_red", category: "esports")).to eq(0.50)
      expect(CalibrationConstant.value_for("phi_red", category: "music")).to eq(0.35)         # → default
      expect(CalibrationConstant.value_for("tau_hard", category: "x", fallback: 0.99)).to eq(0.99) # missing → fallback
      expect(CalibrationConstant.value_for("tau_hard")).to be_nil                             # missing, no fallback
    end
  end
end
