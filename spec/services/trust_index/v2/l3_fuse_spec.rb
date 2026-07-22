# frozen_string_literal: true

require "rails_helper"

module L3FuseSpecDoubles
  Hard = Data.define(:f_hard, :f_hard_lo, :f_hard_hi)
  Soft = Data.define(:f_soft, :f_soft_lo, :f_soft_hi)
  SelfCtx = Data.define(:eligible, :v, :eihc, :rho_self_lo)
end

RSpec.describe TrustIndex::V2::L3Fuse do
  def hard(pt, lo, hi)
    L3FuseSpecDoubles::Hard.new(f_hard: pt, f_hard_lo: lo, f_hard_hi: hi)
  end

  def soft(pt, lo, hi)
    L3FuseSpecDoubles::Soft.new(f_soft: pt, f_soft_lo: lo, f_soft_hi: hi)
  end

  def self_ctx(eligible: false, v: 5000, eihc: 45.0, rho_self_lo: 0.03)
    L3FuseSpecDoubles::SelfCtx.new(eligible: eligible, v: v, eihc: eihc, rho_self_lo: rho_self_lo)
  end

  it "takes the worst of hard/soft (max, not sum — avoids double-count)" do
    fc = described_class.call(hard: hard(300, 268, 332), soft: soft(3500, 2750, 4100), self_ctx: self_ctx)
    expect(fc.f_hat).to eq(3500)          # soft dominates
    expect(fc.f_hat_lo).to eq(2750)
    expect(fc.f_hat_hi).to eq(4100)
    expect(fc.f_self).to eq(0.0)          # not eligible
  end

  # TI v2.1 BUG-A: F_hard (named chatting bots) and F_soft (silent viewbots — EIHC already strips
  # B_hard) are DISJOINT → they ADD under sum_disjoint (gated by the co-windowed flag), fixing the old
  # max's systematic undercount. Default (flag OFF) keeps max (the test above is unchanged).
  it "sum_disjoint: disjoint F_hard + F_soft ADD (not max), per interval bound" do
    fc = described_class.call(hard: hard(300, 268, 332), soft: soft(3500, 2750, 4100),
                              self_ctx: self_ctx, sum_disjoint: true)
    expect(fc.f_hat).to eq(3800)          # 300 + 3500
    expect(fc.f_hat_lo).to eq(3018)       # 268 + 2750
    expect(fc.f_hat_hi).to eq(4432)       # 332 + 4100
  end

  it "sum_disjoint: overlapping F_self still taken as max against the additive hard+soft" do
    fc = described_class.call(hard: hard(100, 100, 100), soft: soft(100, 100, 100),
                              self_ctx: self_ctx(eligible: true, v: 5000, eihc: 10.0, rho_self_lo: 0.01),
                              sum_disjoint: true)
    expect(fc.f_hat).to eq(4000)          # f_self = 5000 − 10/0.01 = 4000 > hard+soft(200)
  end

  it "hard floor dominates when it exceeds the soft bound (named-bot heavy)" do
    fc = described_class.call(hard: hard(3000, 2900, 3100), soft: soft(500, 300, 700), self_ctx: self_ctx)
    expect(fc.f_hat).to eq(3000)
  end

  it "F_self arm adds recall ONLY when eligible (convert-from-honest inflation)" do
    ineligible = described_class.call(hard: hard(0, 0, 0), soft: soft(100, 0, 200), self_ctx: self_ctx(eligible: false))
    expect(ineligible.f_self).to eq(0.0)
    eligible = described_class.call(hard: hard(0, 0, 0), soft: soft(100, 0, 200),
                                    self_ctx: self_ctx(eligible: true, v: 5000, eihc: 45.0, rho_self_lo: 0.03))
    expect(eligible.f_self).to be_within(1e-6).of(3500.0) # 5000 − 45/0.03
    expect(eligible.f_hat).to eq(eligible.f_self)         # F_self now the worst arm
  end
end
