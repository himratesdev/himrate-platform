# frozen_string_literal: true

require "rails_helper"

# Test doubles for the pure classifier (defined outside the example group to avoid
# dynamic-constant-assignment; namespaced to avoid global collisions).
module BandClassifierSpecDoubles
  Drivers = Data.define(:n_frac, :f_self_ratio, :f_soft_lo_ratio, :a_hat, :q, :i_event,
                        :c_hard, :c_self, :c_inflation, :raid_window, :cold_start_tier, :cell_calibrated,
                        :i_event_sustained, :c_pop)
  Thresholds = Data.define(:phi_yellow, :phi_red, :q_mid, :q_hi)
end

RSpec.describe TrustIndex::V2::BandClassifier do
  # Illustrative GATE-0 constants (SRS §5.3 / Glossary §D).
  let(:k) { BandClassifierSpecDoubles::Thresholds.new(phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.5, q_hi: 0.8) }

  def drivers(**over)
    base = { n_frac: 0.0, f_self_ratio: 0.0, f_soft_lo_ratio: 0.0, a_hat: 0.0, q: 0.9,
             i_event: false, c_hard: false, c_self: false, c_inflation: false,
             raid_window: false, cold_start_tier: "full", cell_calibrated: true,
             i_event_sustained: false, c_pop: false }
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

  # G4: cold-start tier gates the SOFT-corroborator accusatory branches (protect brand-new streamers from
  # a corroborator blip against an uncalibrated DEFAULT cell). The named-bot FRACTION branch stays ungated.
  it "G4: a BASIC-tier channel with a C_inflation-corroborated soft deficit is NOT accused (→ AMBER)" do
    b = classify(f_soft_lo_ratio: 0.60, c_inflation: true, a_hat: 0.60, cold_start_tier: "basic")
    expect([ b.row, b.color ]).to eq([ 6, "amber" ]) # soft/corroborator branch gated off for non-full tier
  end

  it "G4: an INSUFFICIENT-tier channel with a corroborated soft deficit is NOT accused" do
    b = classify(f_soft_lo_ratio: 0.60, c_inflation: true, a_hat: 0.60, cold_start_tier: "insufficient")
    expect(%w[red yellow]).not_to include(b.color)
  end

  it "G4: the named-bot FRACTION branch STILL accuses at basic tier (hard, cell-independent)" do
    b = classify(n_frac: 0.58, c_hard: true, a_hat: 0.30, cold_start_tier: "basic")
    expect([ b.row, b.color ]).to eq([ 1, "red" ]) # n_frac ungated by tier
  end

  it "G4 control: the SAME corroborated deficit at FULL tier IS accused (RED)" do
    b = classify(f_soft_lo_ratio: 0.60, c_inflation: true, a_hat: 0.60, cold_start_tier: "full")
    expect([ b.row, b.color ]).to eq([ 1, "red" ])
  end

  it "G4: the i_event/C_self accusatory branch ALSO gates on tier — basic tier does NOT accuse" do
    # Symmetric half of the gate: the self-history branch is dormant today (i_event_enabled=0), but this
    # locks in that when i_event flips, a thin-history channel still can't be accused off it.
    b = classify(i_event: true, c_self: true, f_self_ratio: 0.55, a_hat: 0.55, cold_start_tier: "basic")
    expect(%w[red yellow]).not_to include(b.color)
  end

  # moat-audit (uncovered-cell safety): the f_soft/C_inflation accusatory branch must NEVER fire off an
  # uncalibrated per-cell ρ* (DEFAULT fallback) — only ~10 RU cells are seeded; the rest of the fleet is
  # on the illustrative 0.03 default that could false-accuse a low-chat cell.
  it "moat-audit: an UNCALIBRATED cell + C_inflation-corroborated soft deficit is NOT accused (→ AMBER)" do
    b = classify(f_soft_lo_ratio: 0.60, c_inflation: true, a_hat: 0.60, cell_calibrated: false)
    expect([ b.row, b.color ]).to eq([ 6, "amber" ])
  end

  it "moat-audit: named-bot FRACTION STILL accuses on an uncalibrated cell (cell-independent hard evidence)" do
    b = classify(n_frac: 0.58, c_hard: true, a_hat: 0.30, cell_calibrated: false)
    expect([ b.row, b.color ]).to eq([ 1, "red" ])
  end

  it "moat-audit control: the SAME corroborated soft deficit on a CALIBRATED cell IS accused (RED)" do
    b = classify(f_soft_lo_ratio: 0.60, c_inflation: true, a_hat: 0.60, cell_calibrated: true)
    expect([ b.row, b.color ]).to eq([ 1, "red" ])
  end

  # TI v2.1 C_self^SP row2-cap: a SUSTAINED-only self-history inflation (the held-plateau arm) is a single
  # deficit-family signal → it accuses but caps at YELLOW (row2). Public RED needs a SECOND, INDEPENDENT
  # corroborator (C_hard/C_inflation). The legacy step arm (i_event_sustained=false) keeps its RED path.
  describe "C_self^SP sustained-plateau row2-cap" do
    it "sustained-only i_event + F_self/V ≥ 0.50 caps at YELLOW (row2), NOT RED" do
      b = classify(i_event: true, c_self: true, i_event_sustained: true, f_self_ratio: 0.55, a_hat: 0.55)
      expect([ b.row, b.color ]).to eq([ 2, "yellow" ])
    end

    it "sustained i_event WITH C_hard escalates to RED (independent second corroborator present)" do
      b = classify(i_event: true, c_self: true, i_event_sustained: true, f_self_ratio: 0.55, a_hat: 0.55,
                   c_hard: true, n_frac: 0.05) # n_frac below φ_yellow → the RED comes from the self branch, not n_frac
      expect(b.row).to eq(1)
    end

    it "sustained i_event WITH a CCV-step (C_inflation) escalates to RED" do
      b = classify(i_event: true, c_self: true, i_event_sustained: true, f_self_ratio: 0.55, a_hat: 0.55,
                   c_inflation: true)
      expect(b.row).to eq(1)
    end

    it "control: a LEGACY-step i_event (i_event_sustained=false) + F_self/V ≥ 0.50 still reaches RED" do
      b = classify(i_event: true, c_self: true, i_event_sustained: false, f_self_ratio: 0.55, a_hat: 0.55)
      expect(b.row).to eq(1)
    end

    # A sustained-only C_self shares F_soft's deficit shape → it must NOT self-corroborate the F_soft RED
    # branch (deficit corroborating deficit). A legacy C_self (carries the step conjuncts) still can.
    it "sustained-only C_self does NOT self-corroborate the F_soft RED branch (stays row2 YELLOW)" do
      b = classify(f_soft_lo_ratio: 0.60, c_self: true, i_event: true, i_event_sustained: true,
                   f_self_ratio: 0.0, a_hat: 0.60)
      # f_self branch capped (sustained-only) AND the f_soft branch's only corroborator is the sustained
      # C_self → independently_corroborated? false → f_soft RED branch blocked → YELLOW via f_soft ≥ 0.20.
      expect([ b.row, b.color ]).to eq([ 2, "yellow" ])
    end

    it "a LEGACY-step C_self (i_event_sustained=false) DOES corroborate the F_soft RED branch" do
      b = classify(f_soft_lo_ratio: 0.60, c_self: true, i_event: true, i_event_sustained: false,
                   f_self_ratio: 0.0, a_hat: 0.60)
      expect(b.row).to eq(1)
    end

    it "sustained-only F_soft ≥ 0.20 still reaches YELLOW (an accusation, the intended sustained level)" do
      b = classify(f_soft_lo_ratio: 0.30, c_self: true, i_event: true, i_event_sustained: true, a_hat: 0.30)
      expect([ b.row, b.color ]).to eq([ 2, "yellow" ])
    end
  end

  # TI v2.1 C_pop (population-anchored, silent-always-botter fix): joins corroborated? (YELLOW) but NOT
  # independently_corroborated? (RED) → a population-only accusation caps at YELLOW; RED needs C_hard/
  # C_inflation to ALSO fire (a single mis-priced cell can't alone drive public RED).
  describe "C_pop population-anchored corroborator" do
    it "C_pop corroborates a soft deficit ≥ 0.20 → row2 YELLOW (the always-botter is now accused, not AMBER)" do
      b = classify(f_soft_lo_ratio: 0.30, c_pop: true, a_hat: 0.30)
      expect([ b.row, b.color ]).to eq([ 2, "yellow" ])
    end

    it "C_pop-ONLY caps at YELLOW even at f_soft ≥ 0.50 (never public RED alone)" do
      b = classify(f_soft_lo_ratio: 0.60, c_pop: true, a_hat: 0.60)
      expect([ b.row, b.color ]).to eq([ 2, "yellow" ]) # independently_corroborated? false → RED branch blocked
    end

    it "C_pop + C_hard (independent second axis) escalates to RED" do
      b = classify(f_soft_lo_ratio: 0.60, c_pop: true, c_hard: true, n_frac: 0.05, a_hat: 0.60)
      expect(b.row).to eq(1)
    end

    it "C_pop + C_inflation (a step) escalates to RED" do
      b = classify(f_soft_lo_ratio: 0.60, c_pop: true, c_inflation: true, a_hat: 0.60)
      expect(b.row).to eq(1)
    end

    it "C_pop without a soft deficit never accuses (the deficit AND-corroboration gate holds)" do
      b = classify(f_soft_lo_ratio: 0.0, c_pop: true, a_hat: 0.05, q: 0.9, cold_start_tier: "full")
      expect(b.row).to be > 2
    end

    it "G4: C_pop on a BASIC-tier channel is NOT accused (→ AMBER)" do
      b = classify(f_soft_lo_ratio: 0.30, c_pop: true, a_hat: 0.30, cold_start_tier: "basic")
      expect([ b.row, b.color ]).to eq([ 6, "amber" ])
    end

    it "moat-audit: C_pop on an UNCALIBRATED cell is NOT accused (double-gated → AMBER)" do
      b = classify(f_soft_lo_ratio: 0.30, c_pop: true, a_hat: 0.30, cell_calibrated: false)
      expect([ b.row, b.color ]).to eq([ 6, "amber" ])
    end
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
