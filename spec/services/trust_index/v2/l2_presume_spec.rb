# frozen_string_literal: true

require "rails_helper"

module L2PresumeSpecDoubles
  Chatter = Data.define(:username, :cluster_delta_k, :cluster_size, :age_gate, :recurrence_gate)
  Cell = Data.define(:rho_star, :rho_lo, :rho_hi)
  K = Data.define(:tau_delta).new(tau_delta: 0.5)
end

RSpec.describe TrustIndex::V2::L2Presume do
  let(:k) { L2PresumeSpecDoubles::K }
  let(:cell) { L2PresumeSpecDoubles::Cell.new(rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05) }

  def chatter(name, **over)
    base = { username: name, cluster_delta_k: 0.0, cluster_size: 1, age_gate: 1.0, recurrence_gate: 1.0 }
    L2PresumeSpecDoubles::Chatter.new(**base.merge(over))
  end

  it "recalls the silent-farm deficit as an ERV COUNT (S3: V=5000, ~45 human chatters)" do
    raw = Array.new(45) { |i| chatter("h#{i}") }
    sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k)
    expect(sb.eihc).to be_within(1e-9).of(45.0)
    expect(sb.f_soft).to be_within(1e-6).of(5000 - 45 / 0.03)      # ≈ 3500
    expect(sb.f_soft_lo).to be < sb.f_soft                          # lenient ρ_lo → smaller, gates label
    expect(sb.f_soft_hi).to be > sb.f_soft
  end

  it "excludes B_hard from EIHC (named bots don't count as human engagement)" do
    raw = [ chatter("human"), chatter("botA") ]
    sb = described_class.call(raw: raw, b_hard_usernames: Set.new(%w[botA]), v: 100, cell: cell, k: k)
    expect(sb.eihc).to eq(1.0)
  end

  it "an honest channel (engagement explains V) yields F_soft_lo ≈ 0 (no accusation)" do
    raw = Array.new(60) { |i| chatter("h#{i}") } # EIHC 60, ρ_lo 0.05 → 1200 ≥ 1000
    sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 1000,
                             cell: L2PresumeSpecDoubles::Cell.new(rho_star: 0.05, rho_lo: 0.05, rho_hi: 0.08), k: k)
    expect(sb.f_soft_lo).to eq(0.0)
  end
end
