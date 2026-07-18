# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::V2::CellResolver do
  def baseline(attrs)
    CalibrationCellBaseline.create!({ chat_mode: "open", language: "ru", sample_size: 100 }.merge(attrs))
  end

  it "resolves the exact cell's ρ* triple" do
    baseline(category: "gaming", v_bucket: "1k-5k", rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05, calibrated: true)
    r = described_class.call(category: "gaming", v_bucket: "1k-5k", chat_mode: "open", language: "ru")
    expect([ r.rho_star, r.rho_lo, r.rho_hi ]).to eq([ 0.03, 0.02, 0.05 ])
  end

  it "falls back to the default category when the exact cell is absent" do
    baseline(category: "default", v_bucket: "1k-5k", rho_star: 0.06, rho_lo: 0.03, rho_hi: 0.10, calibrated: true)
    r = described_class.call(category: "asmr", v_bucket: "1k-5k", chat_mode: "open", language: "ru")
    expect(r.rho_star).to eq(0.06)
  end

  it "walks the parent chain to the nearest calibrated ancestor (hierarchical shrinkage)" do
    parent = baseline(category: "default", v_bucket: "1k-5k", rho_star: 0.06, rho_lo: 0.03, rho_hi: 0.10, calibrated: true)
    baseline(category: "gaming", v_bucket: "1k-5k", rho_star: 0.04, rho_lo: 0.02, rho_hi: 0.07,
             calibrated: false, parent_cell: parent)
    r = described_class.call(category: "gaming", v_bucket: "1k-5k", chat_mode: "open", language: "ru")
    expect(r.rho_star).to eq(0.06) # uncalibrated leaf → resolved to calibrated parent
  end

  it "returns nil when nothing matches (caller decides cold-start)" do
    expect(described_class.call(category: "x", v_bucket: "99k", chat_mode: "open", language: "ru")).to be_nil
  end
end
