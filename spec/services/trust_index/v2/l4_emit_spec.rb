# frozen_string_literal: true

require "rails_helper"

module L4EmitSpecDoubles
  Hard = Data.define(:f_hard, :f_hard_lo, :f_hard_hi)
  Soft = Data.define(:eihc, :rho_obs, :f_soft, :f_soft_lo, :f_soft_hi)
  Fraud = Data.define(:f_hat, :f_hat_lo, :f_hat_hi, :f_self)
  Ctx = Data.define(:v, :n_chat_eff, :q, :i_event, :raid_window, :cold_start_tier, :named_count,
                    :self_history_stable, :chatter_quality_high, :stream_count, :unattributed_surge, :thin_sample)
  K = Data.define(:phi_yellow, :phi_red, :q_mid, :q_hi).new(phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.5, q_hi: 0.8)
end

RSpec.describe TrustIndex::V2::L4Emit do
  let(:k) { L4EmitSpecDoubles::K }

  def emit(hard:, soft:, fraud:, **ctx_over)
    ctx_base = { v: 5000, n_chat_eff: 500, q: 0.9, i_event: false, raid_window: false,
                 cold_start_tier: "full", named_count: 0, self_history_stable: false,
                 chatter_quality_high: false, stream_count: 20, unattributed_surge: false, thin_sample: false }
    described_class.call(hard: hard, soft: soft, fraud: fraud,
                         ctx: L4EmitSpecDoubles::Ctx.new(**ctx_base.merge(ctx_over)), k: k)
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
end
