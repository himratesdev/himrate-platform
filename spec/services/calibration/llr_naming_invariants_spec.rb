# frozen_string_literal: true

require "rails_helper"

# FULL-CHAIN M1 (2026-07-27) — executable naming-stack invariants for the L0 identity path.
#
# b_hard (public naming, ≥99%-precision legal bar) fires when a SINGLE identity's summed LLR crosses
# τ_gap = logit(τ_hard) − logit(π0). LLR is a SUM, so a future data-write to ANY positive LLR source can
# silently create a NEW naming class by stacking (e.g. bumping llr_temporal_r3 so R3+known_bot ≥ τ_gap).
# These are the FP-SAFETY invariants that must hold so no sub-confirmed tier gains naming power by accident.
# They are "must-NOT-name" bounds only — deliberately NOT asserting that any tier DOES name (that is a
# product/legal decision, not a safety property). Runs on the Registry defaults (the fallback floor); the
# ops task `ti_v2:verify_llr_invariants` asserts the SAME bounds on the live DB-merged table before a flip.
RSpec.describe "L0 LLR naming-stack invariants (FULL-CHAIN M1)" do
  let(:k) { Calibration::Registry.load } # no DB rows in the spec → the ILLUSTRATIVE floor

  # τ_gap derived from pi0/tau_hard (NOT hardcoded) so a future π0/τ recalibration re-derives the bound.
  def tau_gap(k)
    Math.log(k.tau_hard / (1.0 - k.tau_hard)) - Math.log(k.pi0 / (1.0 - k.pi0))
  end

  it "τ_gap resolves to ~6.089 at the illustrative π0=0.02 / τ_hard=0.90" do
    expect(tau_gap(k)).to be_within(1e-3).of(6.089)
  end

  # I1/I2: a sub-confirmed temporal tier (R=2 / R=3) stacked with a known-bot hit must NOT reach naming.
  # (R=3's honest-fraction is unquantified — SRS OQ-6 — so R3 must never name even with a corroborating hit.)
  it "I1: R2 + known_bot stays below τ_gap (R=2 can never name, even with a known-bot hit)" do
    expect(k.llr_temporal_r2 + k.llr_known_bot).to be < tau_gap(k)
  end

  it "I2: R3 + known_bot stays below τ_gap (R=3 can never name — honest-fraction unquantified)" do
    expect(k.llr_temporal_r3 + k.llr_known_bot).to be < tau_gap(k)
  end

  # I3: a solo R4-6 tier must stay a full logit below τ_gap (never names alone, with margin). R4+known
  # naming IS intentional (the calibrated (known ∧ R4-6) class, I4) and is deliberately NOT bounded here.
  it "I3: solo R4-6 stays ≥ 1 logit below τ_gap (never names alone)" do
    expect(k.llr_temporal_r4).to be < (tau_gap(k) - 1.0)
  end

  # Extensibility guard: per_user_bot_score is DEAD (LlrCalibrator multiplies a nil signal → 0) but its
  # illustrative LLR (3.9) + known_bot (3.4) = 7.3 ≥ τ_gap. If per_user is ever RE-WIRED at that LLR it
  # re-opens the account_profile-style naming FP door (red-team-killed). Assert the latent hazard so a
  # future wiring can't merge silently: per_user + known_bot must NOT be a naming stack — i.e. re-wiring
  # per_user REQUIRES dropping its LLR first. Documented as a design tripwire, not a passing bound today.
  it "TRIPWIRE: re-wiring per_user_bot_score at its illustrative LLR would re-create a naming FP door" do
    stack = k.llr_per_user_bot_score + k.llr_known_bot
    # This SUM crosses τ_gap → per_user MUST stay nil-fed (dead) OR its LLR be lowered before any wiring.
    # The assertion documents the invariant the calibrator relies on: per_user contributes 0 in production.
    expect(stack).to be >= tau_gap(k) # if this ever goes FALSE (LLR lowered), the tripwire is satisfied structurally
    # The real guarantee lives in LlrCalibrator#per_user: `s ? s * llr : 0.0` with s always nil in prod.
    silent = TrustIndex::V2::LlrCalibrator.sum_llr(
      Struct.new(:temporal_recurrence, :known_bot_hit, :per_user_bot_score, :account_profile_llr, :anti_bot_llr)
            .new(nil, false, nil, 0.0, 0.0), k: k
    )
    expect(silent).to eq(0.0) # per_user nil → 0 → no naming; the calibrator honors the dead-source contract
  end
end
