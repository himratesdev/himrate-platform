# frozen_string_literal: true

require "rails_helper"

# Test doubles for the pure classifier (defined outside the example group to avoid
# dynamic-constant-assignment; namespaced to avoid global collisions).
module BandClassifierSpecDoubles
  Drivers = Data.define(:n_frac, :f_self_ratio, :f_soft_lo_ratio, :a_hat, :q, :i_event,
                        :c_hard, :c_self, :c_inflation, :raid_window, :cold_start_tier)
  Thresholds = Data.define(:phi_yellow, :phi_red, :q_mid, :q_hi)
end

RSpec.describe TrustIndex::V2::BandClassifier do
  # Illustrative GATE-0 constants (SRS §5.3 / Glossary §D).
  let(:k) { BandClassifierSpecDoubles::Thresholds.new(phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.5, q_hi: 0.8) }

  def drivers(**over)
    base = { n_frac: 0.0, f_self_ratio: 0.0, f_soft_lo_ratio: 0.0, a_hat: 0.0, q: 0.9,
             i_event: false, c_hard: false, c_self: false, c_inflation: false,
             raid_window: false, cold_start_tier: "full" }
    BandClassifierSpecDoubles::Drivers.new(**base.merge(over))
  end

  def classify(**over)
    described_class.call(drivers: drivers(**over), k: k)
  end

  it "row 1 RED — named-bot fraction ≥ φ_red (S1: N_frac 0.58)" do
    b = classify(n_frac: 0.58, c_hard: true, a_hat: 0.30)
    expect([ b.row, b.color ]).to eq([ 1, "red" ])
  end

  it "row 1 RED — self-history inflation with F_self/V ≥ 0.50 (convert-from-honest)" do
    b = classify(i_event: true, c_self: true, f_self_ratio: 0.55, a_hat: 0.55)
    expect(b.row).to eq(1)
  end

  it "row 2 YELLOW — named fraction ≥ φ_yellow but < φ_red" do
    b = classify(n_frac: 0.15, c_hard: true, a_hat: 0.15)
    expect([ b.row, b.color ]).to eq([ 2, "yellow" ])
  end

  it "row 3 GREEN 'Аудитория реальная' — low â + high Q + full tier + no anomaly" do
    b = classify(a_hat: 0.05, q: 0.9, cold_start_tier: "full")
    expect([ b.row, b.color, b.label_key ]).to eq([ 3, "green", "band.green_real" ])
  end

  it "row 4 GREEN 'Аномалий не замечено' — moderate â + mid Q (basic tier ok)" do
    b = classify(a_hat: 0.18, q: 0.6, cold_start_tier: "basic")
    expect([ b.row, b.color ]).to eq([ 4, "green" ])
  end

  it "row 5 GREY — insufficient cold-start tier with no deficit" do
    b = classify(a_hat: 0.10, cold_start_tier: "insufficient")
    expect([ b.row, b.color ]).to eq([ 5, "grey" ])
  end

  it "row 6 AMBER 6a — soft deficit alone NEVER accuses (S3 silent farm, no corroboration)" do
    b = classify(a_hat: 0.30, q: 0.2, f_soft_lo_ratio: 0.30, cold_start_tier: "full") # uncorroborated deficit
    expect([ b.row, b.color, b.sub ]).to eq([ 6, "amber", "6a" ])
  end

  it "row 6 AMBER 6b — heavy uncorroborated deficit (â > 0.50)" do
    b = classify(a_hat: 0.70, q: 0.2, f_soft_lo_ratio: 0.70, cold_start_tier: "full")
    expect([ b.row, b.sub ]).to eq([ 6, "6b" ])
  end

  it "soft deficit ≥ 0.50 WITH corroboration escalates to row 1 (not amber)" do
    b = classify(f_soft_lo_ratio: 0.60, c_hard: true, a_hat: 0.60)
    expect(b.row).to eq(1)
  end

  # TI v2.1 — C_inflation is the INDEPENDENT third corroboration source (CCV-shape silent-injection
  # signature) that breaks the C_hard monoculture: a soft deficit that today dead-ends at AMBER can
  # now escalate when the CCV rose without a matching chat-rate rise.
  it "soft deficit ≥ 0.20 corroborated by C_inflation escalates AMBER→YELLOW (monoculture break)" do
    b = classify(f_soft_lo_ratio: 0.25, c_inflation: true, a_hat: 0.25)
    expect([ b.row, b.color ]).to eq([ 2, "yellow" ])
  end

  it "soft deficit ≥ 0.50 corroborated by C_inflation escalates to row 1 RED" do
    b = classify(f_soft_lo_ratio: 0.60, c_inflation: true, a_hat: 0.60)
    expect(b.row).to eq(1)
  end

  it "C_inflation WITHOUT a soft deficit never accuses (the deficit AND-corroboration gate holds)" do
    b = classify(f_soft_lo_ratio: 0.0, c_inflation: true, a_hat: 0.05, q: 0.9, cold_start_tier: "full")
    expect(b.row).to be > 2 # green/amber, not row 1/2
  end

  it "first-match precedence — RED wins even when green-ish â is low" do
    b = classify(n_frac: 0.40, c_hard: true, a_hat: 0.05, q: 0.9) # A≈95 but named fraction is damning
    expect(b.row).to eq(1)
  end

  describe ".label_key_for (surface-audit sweep — the ONE reader-side derivation point)" do
    it "maps every persisted row to its canonical key" do
      expect(described_class.label_key_for(3)).to eq("band.green_real")
      expect(described_class.label_key_for(4)).to eq("band.green_no_anomaly")
      expect(described_class.label_key_for(6)).to eq("band.amber_exceeds")
    end

    it "falls back to the grey key for nil/unknown rows (grey fallback contract)" do
      expect(described_class.label_key_for(nil)).to eq("band.grey_insufficient")
      expect(described_class.label_key_for(99)).to eq("band.grey_insufficient")
    end
  end
end
