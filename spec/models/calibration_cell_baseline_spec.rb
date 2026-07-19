# frozen_string_literal: true

require "rails_helper"

# T1-074 (TI v2) — CalibrationCellBaseline: per-cell honest ρ* baseline for L2 F_soft.
RSpec.describe CalibrationCellBaseline do
  def baseline(attrs = {})
    described_class.new({
      category: "just_chatting", v_bucket: "1k-5k", chat_mode: "open", language: "ru",
      rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05
    }.merge(attrs))
  end

  it "validates presence, positivity, and the ρ_lo ≤ ρ_star ≤ ρ_hi ordering" do
    expect(baseline).to be_valid
    expect(baseline(rho_lo: 0.04)).not_to be_valid                              # lo > star
    expect(baseline(rho_hi: 0.01)).not_to be_valid                              # hi < star
    expect(baseline(rho_star: 0)).not_to be_valid                              # not > 0
    expect(baseline(rho_lo: 0.03, rho_star: 0.03, rho_hi: 0.03)).to be_valid    # equality boundary OK
  end

  it "skips the ordering check when any bound is nil (presence validation owns that path)" do
    rec = baseline(rho_lo: nil)
    expect(rec).not_to be_valid
    expect(rec.errors[:rho_lo]).not_to include("must be ≤ rho_star ≤ rho_hi")
  end

  describe ".for_cell" do
    before do
      described_class.create!(category: "just_chatting", v_bucket: "1k-5k", chat_mode: "open",
                              language: "ru", rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05)
    end

    it "resolves the exact cell, nil when absent" do
      exact = described_class.for_cell(category: "just_chatting", v_bucket: "1k-5k",
                                       chat_mode: "open", language: "ru")
      expect(exact.rho_star).to eq(0.03)
      expect(described_class.for_cell(category: "asmr", v_bucket: "1k-5k",
                                      chat_mode: "open", language: "ru")).to be_nil
    end
  end

  describe "#resolved (hierarchical shrinkage up the parent chain)" do
    it "returns the nearest calibrated ancestor" do
      root = described_class.create!(category: "default", v_bucket: "1k-5k", chat_mode: "open",
                                     language: "ru", rho_star: 0.06, rho_lo: 0.03, rho_hi: 0.10,
                                     calibrated: true)
      leaf = described_class.create!(category: "asmr", v_bucket: "1k-5k", chat_mode: "open",
                                     language: "ru", rho_star: 0.02, rho_lo: 0.01, rho_hi: 0.04,
                                     calibrated: false, parent_cell: root)
      expect(leaf.resolved).to eq(root)
      expect(root.resolved).to eq(root)
    end
  end
end
