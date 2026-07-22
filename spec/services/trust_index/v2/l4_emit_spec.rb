# frozen_string_literal: true

require "rails_helper"

module L4EmitSpecDoubles
  Hard = Data.define(:f_hard, :f_hard_lo, :f_hard_hi)
  Soft = Data.define(:eihc, :rho_obs, :f_soft, :f_soft_lo, :f_soft_hi)
  Fraud = Data.define(:f_hat, :f_hat_lo, :f_hat_hi, :f_self)
  Ctx = Data.define(:v, :n_chat_eff, :q, :i_event, :raid_window, :cold_start_tier, :named_count,
                    :self_history_stable, :chatter_quality_high, :stream_count, :unattributed_surge,
                    :thin_sample, :ccv_chat_divergence, :v_w)
  K = Data.define(:phi_yellow, :phi_red, :q_mid, :q_hi).new(phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.5, q_hi: 0.8)
  # TI v2.1 — K variant with the inflation corroborator ENABLED (for the escalation test). The
  # dormant default (enabled 0.0) is exercised by the base K above, which lacks the keys entirely →
  # L4's respond_to? guard makes C_inflation false (byte-identical to pre-v2.1).
  K_INFLATION_ON = Data.define(:phi_yellow, :phi_red, :q_mid, :q_hi, :inflation_corrob_enabled, :phi_inflation)
                       .new(phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.5, q_hi: 0.8,
                            inflation_corrob_enabled: 1.0, phi_inflation: 0.30)
  # PRODUCTION dormant shape: K RESPONDS to inflation_corrob_enabled but the value is 0.0 (the real
  # Registry default). Exercises the .positive? flip-guard, not just the respond_to? guard.
  K_INFLATION_OFF = Data.define(:phi_yellow, :phi_red, :q_mid, :q_hi, :inflation_corrob_enabled, :phi_inflation)
                        .new(phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.5, q_hi: 0.8,
                             inflation_corrob_enabled: 0.0, phi_inflation: 0.30)
end

RSpec.describe TrustIndex::V2::L4Emit do
  let(:k) { L4EmitSpecDoubles::K }

  def emit(hard:, soft:, fraud:, k_override: nil, **ctx_over)
    ctx_base = { v: 5000, n_chat_eff: 500, q: 0.9, i_event: false, raid_window: false,
                 cold_start_tier: "full", named_count: 0, self_history_stable: false,
                 chatter_quality_high: false, stream_count: 20, unattributed_surge: false,
                 thin_sample: false, ccv_chat_divergence: 0.0, v_w: nil }
    described_class.call(hard: hard, soft: soft, fraud: fraud,
                         ctx: L4EmitSpecDoubles::Ctx.new(**ctx_base.merge(ctx_over)), k: k_override || k)
  end

  def hard(lo)
    L4EmitSpecDoubles::Hard.new(f_hard: lo, f_hard_lo: lo, f_hard_hi: lo)
  end

  def soft(lo = 0.0)
    L4EmitSpecDoubles::Soft.new(eihc: 45.0, rho_obs: 0.009, f_soft: lo, f_soft_lo: lo, f_soft_hi: lo)
  end

  def fraud(pt)
    L4EmitSpecDoubles::Fraud.new(f_hat: pt, f_hat_lo: pt, f_hat_hi: pt, f_self: 0.0)
  end

  it "S1 named-bot heavy → ERV = V−F̂, RED band, C_hard plashka + HARD_NAMED_FRACTION" do
    # 290 named of 500 effective chatters → N_frac 0.58 ≥ φ_red
    r = emit(hard: hard(290.0), soft: soft(0.0), fraud: fraud(3000.0), named_count: 290)
    expect(r.erv).to eq(2000.0)
    expect(r.n_frac).to be_within(1e-6).of(0.58)
    expect([ r.band.row, r.band.color ]).to eq([ 1, "red" ])
    expect(r.confirmed_anomaly).to be(true)
    expect(r.reason_codes.map(&:code)).to include("HARD_NAMED_FRACTION")
  end

  it "heavy soft deficit + low-Q correlated chat (no named bots) → AMBER 6b, NO plashka" do
    r = emit(hard: hard(0.0), soft: soft(2750.0), fraud: fraud(3500.0), q: 0.2)
    expect(r.erv).to eq(1500.0)
    expect(r.a_hat).to be_within(1e-6).of(0.70)
    expect([ r.band.row, r.band.color, r.band.sub ]).to eq([ 6, "amber", "6b" ])
    expect(r.confirmed_anomaly).to be(false)
    expect(r.reason_codes.map(&:code)).to eq([ "CHATTER_QUALITY_LOW" ])
  end

  it "clean channel → high ERV, GREEN 'Аудитория реальная', authenticity ~100" do
    r = emit(hard: hard(0.0), soft: soft(0.0), fraud: fraud(50.0), self_history_stable: true, chatter_quality_high: true)
    expect(r.erv).to eq(4950.0)
    expect(r.authenticity).to be_within(0.5).of(99.0)
    expect([ r.band.row, r.band.color ]).to eq([ 3, "green" ])
    expect(r.confirmed_anomaly).to be(false)
  end

  it "erv interval derives from the fraud interval inverted (erv_lo = V−F̂_hi)" do
    f = L4EmitSpecDoubles::Fraud.new(f_hat: 1000.0, f_hat_lo: 800.0, f_hat_hi: 1200.0, f_self: 0.0)
    r = emit(hard: hard(0.0), soft: soft(0.0), fraud: f)
    expect([ r.erv_lo, r.erv, r.erv_hi ]).to eq([ 3800.0, 4000.0, 4200.0 ])
  end

  it "confidence_marker: basic tier or thin sample → provisional, else reliable" do
    expect(emit(hard: hard(0.0), soft: soft(0.0), fraud: fraud(50.0)).confidence_marker).to eq("reliable")
    expect(emit(hard: hard(0.0), soft: soft(0.0), fraud: fraud(50.0), cold_start_tier: "basic")
      .confidence_marker).to eq("provisional")
    expect(emit(hard: hard(0.0), soft: soft(0.0), fraud: fraud(50.0), thin_sample: true)
      .confidence_marker).to eq("provisional")
  end

  it "C_self convert-from-honest (I=1, F_self-dominant) → accusatory band + SELF_HISTORY_INFLATION_EVENT (EC-7)" do
    f = L4EmitSpecDoubles::Fraud.new(f_hat: 3000.0, f_hat_lo: 2800.0, f_hat_hi: 3200.0, f_self: 3000.0) # F_self/V=0.6
    r = emit(hard: hard(0.0), soft: soft(0.0), fraud: f, i_event: true)
    expect(r.c_self).to be(true)
    expect(r.confirmed_anomaly).to be(true)
    expect([ 1, 2 ]).to include(r.band.row)          # accusatory (RED/YELLOW), not AMBER
    expect(r.reason_codes.map(&:code)).to include("SELF_HISTORY_INFLATION_EVENT")
  end

  # ── TI v2.1 inflation-event corroborator (BUG-A/B pivot) ──
  # DORMANT default: the base K lacks the inflation constants → respond_to? guard makes C_inflation
  # false, so even a maximal CCV-shape signature leaves a soft deficit at AMBER (byte-identical to
  # pre-v2.1). This is the zero-behavior-change proof for merge.
  it "DORMANT: default K → C_inflation never fires; a max CCV-shape signature leaves the deficit at AMBER" do
    r = emit(hard: hard(0.0), soft: soft(1250.0), fraud: fraud(1250.0), ccv_chat_divergence: 0.9)
    expect([ r.band.row, r.band.color ]).to eq([ 6, "amber" ])
    expect(r.confirmed_anomaly).to be(false)
    expect(r.reason_codes.map(&:code)).not_to include("INFLATION_EVENT_CORROBORATION")
  end

  # The exact PRODUCTION flip-guard: K has the constant but it is 0.0 (Registry default) → .positive?
  # false → C_inflation false even with a maximal divergence. This is what protects prod until the flip.
  it "DORMANT (production K shape): inflation_corrob_enabled=0.0 → max divergence still AMBER, no escalation" do
    r = emit(hard: hard(0.0), soft: soft(1250.0), fraud: fraud(1250.0),
             ccv_chat_divergence: 0.9, k_override: L4EmitSpecDoubles::K_INFLATION_OFF)
    expect([ r.band.row, r.band.color ]).to eq([ 6, "amber" ])
    expect(r.confirmed_anomaly).to be(false)
    expect(r.reason_codes.map(&:code)).not_to include("INFLATION_EVENT_CORROBORATION")
  end

  # FLIP (PO-gated, post-BUG-A): with the corroborator enabled, a soft deficit corroborated by the
  # CCV-shape inflation signature escalates AMBER→YELLOW — the monoculture break, naming nobody.
  it "ENABLED: soft deficit + inflation signature escalates AMBER→YELLOW + INFLATION_EVENT_CORROBORATION" do
    r = emit(hard: hard(0.0), soft: soft(1250.0), fraud: fraud(1250.0),
             ccv_chat_divergence: 0.5, k_override: L4EmitSpecDoubles::K_INFLATION_ON)
    expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ])
    expect(r.confirmed_anomaly).to be(true)
    expect(r.reason_codes.map(&:code)).to include("INFLATION_EVENT_CORROBORATION")
  end

  it "ENABLED: an organic raid window suppresses C_inflation (no false escalation)" do
    r = emit(hard: hard(0.0), soft: soft(1250.0), fraud: fraud(1250.0),
             ccv_chat_divergence: 0.5, raid_window: true, k_override: L4EmitSpecDoubles::K_INFLATION_ON)
    expect(r.band.row).to eq(6) # stays AMBER — raid excluded from the corroborator
    expect(r.confirmed_anomaly).to be(false)
  end

  # TI v2.1 BUG-A V-frame split (red-team fix): band-driver ratios divide by V_W (deficit frame),
  # display (authenticity/ERV) by instant V. f_soft_lo=350: instant 350/2000=0.175 MISSES row-2
  # (≥0.20) but windowed 350/1400=0.25 FIRES — so a viewbot spike (V_inst≫V_W) can no longer dilute
  # the accusatory ratio out of range.
  it "BUG-A: band ratios use V_W while authenticity uses instant V (co-windowed)" do
    r = emit(hard: hard(0.0), soft: soft(350.0), fraud: fraud(350.0), v: 2000, v_w: 1400,
             ccv_chat_divergence: 0.5, k_override: L4EmitSpecDoubles::K_INFLATION_ON)
    expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ]) # 350/1400=0.25 ≥ 0.20 + corroborated
    expect(r.authenticity).to be_within(0.5).of(82.5)           # display = instant: 100·(1−350/2000)
  end

  it "BUG-A dormant (v_w nil): the same deficit stays AMBER — instant-V band frame, byte-identical" do
    r = emit(hard: hard(0.0), soft: soft(350.0), fraud: fraud(350.0), v: 2000,
             ccv_chat_divergence: 0.5, k_override: L4EmitSpecDoubles::K_INFLATION_ON)
    expect(r.band.row).to eq(6) # 350/2000=0.175 < 0.20 → no row-2 → AMBER (frame is instant V when dormant)
  end
end
