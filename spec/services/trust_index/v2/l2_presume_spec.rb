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

  # TI v2.1 BUG-A co-windowed ρ_obs.
  it "dormant (windowed_usernames/v_w nil) is byte-identical to the legacy cumulative call" do
    raw = Array.new(45) { |i| chatter("h#{i}") }
    legacy = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k)
    dormant = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k,
                                   windowed_usernames: nil, v_w: nil)
    expect(dormant.to_h).to eq(legacy.to_h)
  end

  it "co-windowed: a cumulative-CLEAN mature stream surfaces the deficit its departed chatters whitened" do
    raw = Array.new(100) { |i| chatter("h#{i}") }        # 100 cumulative chatters
    windowed = Set.new(Array.new(5) { |i| "h#{i}" })     # only 5 active in the last 60min
    flat = L2PresumeSpecDoubles::Cell.new(rho_star: 0.03, rho_lo: 0.03, rho_hi: 0.03)
    # Cumulative (dormant): EIHC 100, V 3000 → 100/0.03 = 3333 ≥ 3000 → F_soft 0 (whitened clean).
    dormant = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 3000, cell: flat, k: k)
    expect(dormant.f_soft).to eq(0.0)
    # Co-windowed: EIHC 5 (subset), V_W 2800 → 2800 − 5/0.03 ≈ 2633 deficit surfaces.
    win = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 3000, cell: flat, k: k,
                               windowed_usernames: windowed, v_w: 2800)
    expect(win.f_soft).to be_within(1.0).of(2800 - 5 / 0.03)
    expect(win.rho_obs).to be_within(1e-6).of(5 / 2800.0) # ρ_obs = EIHC_W / V_W (both windowed)
  end
end
