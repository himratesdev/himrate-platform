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

  it "G1: a decaying young stream (V_W > V_inst) caps the deficit V at instant online — no false deficit" do
    raw = Array.new(30) { |i| chatter("h#{i}") }         # thin honest chat, EIHC 30
    windowed = Set.new(raw.map(&:username))              # young: window == whole roster (EIHC unchanged)
    flat = L2PresumeSpecDoubles::Cell.new(rho_star: 0.03, rho_lo: 0.03, rho_hi: 0.03)
    # Early spike then decay: windowed median V_W=1500 (stale-high) but current instant online V_inst=300.
    # Uncapped V_W: max(0, 1500 − 30/0.03) = 500 FALSE deficit. Capped min(1500,300)=300: max(0, 300 − 1000) = 0.
    win = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 300, cell: flat, k: k,
                               windowed_usernames: windowed, v_w: 1500)
    expect(win.f_soft).to eq(0.0)                          # decay FP removed — a falling online hides no injection
    expect(win.rho_obs).to be_within(1e-6).of(30 / 300.0)  # ρ_obs = EIHC_W / min(V_W, V_inst)
  end

  # BUG-EIHC-500CAP: the roster reads are alphabetical ≤500 SAMPLES — EIHC = sample RATE × uncapped
  # n_roster, never the raw sample sum divided by the full online.
  describe "n_roster scale correction (BUG-EIHC-500CAP)" do
    let(:cap_cell) { L2PresumeSpecDoubles::Cell.new(rho_star: 0.05, rho_lo: 0.05, rho_hi: 0.05) }

    it "scales the sample rate by the uncapped windowed count (stariy_bog shape: capped AMBER → clean)" do
      raw = Array.new(100) { |i| chatter(format("h%03d", i)) } # cumulative alphabetical sample
      windowed = Set.new(raw.first(40).map(&:username))        # prefix-drift: only 40 land in the window sample
      capped = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 3200, cell: cap_cell, k: k,
                                    windowed_usernames: windowed, v_w: 3000) # n_roster absent → pre-fix magnitude
      expect(capped.eihc).to eq(40.0)
      expect(capped.f_soft).to be_within(1.0).of(3000 - 40 / 0.05) # 2200 FALSE deficit
      fixed = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 3200, cell: cap_cell, k: k,
                                   windowed_usernames: windowed, v_w: 3000, n_roster: 400)
      expect(fixed.eihc).to be_within(1e-9).of(400.0)              # rate 40/40 = 1.0 × 400
      expect(fixed.rho_obs).to be_within(1e-6).of(400 / 3000.0)
      expect(fixed.f_soft).to eq(0.0)                              # 400/0.05 = 8000 explains all of V_W
    end

    it "is byte-identical below the cap (n_roster == sample size → rate × n == Σw)" do
      raw = Array.new(45) { |i| chatter("h#{i}") }
      windowed = Set.new(raw.map(&:username))
      legacy = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k,
                                    windowed_usernames: windowed, v_w: 4800)
      scaled = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k,
                                    windowed_usernames: windowed, v_w: 4800, n_roster: 45)
      expect(scaled.to_h).to eq(legacy.to_h)
    end

    it "keeps the named-bot share in the rate (a chatting botnet depresses scaled EIHC proportionally)" do
      humans = Array.new(30) { |i| chatter(format("h%03d", i)) }
      bots = Array.new(10) { |i| chatter(format("b%03d", i)) }
      raw = humans + bots
      windowed = Set.new(raw.map(&:username))
      sb = described_class.call(raw: raw, b_hard_usernames: Set.new(bots.map(&:username)), v: 3200,
                                cell: cap_cell, k: k, windowed_usernames: windowed, v_w: 3000, n_roster: 400)
      expect(sb.eihc).to be_within(1e-9).of((30 / 40.0) * 400)     # rate 0.75 × 400 = 300
    end

    it "never scales DOWN on a cross-query race (n_roster < sample size → sample size wins)" do
      raw = Array.new(40) { |i| chatter("h#{i}") }
      windowed = Set.new(raw.map(&:username))
      sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 3200, cell: cap_cell, k: k,
                                windowed_usernames: windowed, v_w: 3000, n_roster: 10)
      expect(sb.eihc).to eq(40.0)                                  # max(n_roster, base.size) guard
    end

    it "falls back to the cumulative-sample rate when the two alphabetical prefixes fully drift apart" do
      raw = Array.new(50) { |i| chatter("a#{format('%02d', i)}") }         # cumulative prefix: a…
      windowed = Set.new(Array.new(50) { |i| "z#{format('%02d', i)}" })    # windowed prefix: z… (disjoint)
      sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 3200, cell: cap_cell, k: k,
                                windowed_usernames: windowed, v_w: 3000, n_roster: 400)
      expect(sb.eihc).to be_within(1e-9).of(400.0)                 # rate over raw (1.0) × n_roster
    end

    it "scales the cumulative frame too (flag-OFF rollback path is not left capped)" do
      raw = Array.new(100) { |i| chatter("h#{i}") }
      sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 20_000, cell: cap_cell, k: k,
                                n_roster: 800)
      expect(sb.eihc).to be_within(1e-9).of(800.0)                 # rate 1.0 × cumulative uncapped count
      expect(sb.f_soft).to be_within(1.0).of(20_000 - 800 / 0.05)  # deficit on the TRUE magnitude
    end
  end

  # FULL-CHAIN M4 shared deficit-family absolute floor (deficit_min_ccv).
  it "M4 dormant (deficit_min_ccv nil / 0.0) is byte-identical to the guardless call" do
    raw = Array.new(45) { |i| chatter("h#{i}") }
    guardless = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k)
    off_nil = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k, deficit_min_ccv: nil)
    off_zero = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 5000, cell: cell, k: k, deficit_min_ccv: 0.0)
    expect(off_nil.to_h).to eq(guardless.to_h)
    expect(off_zero.to_h).to eq(guardless.to_h)
  end

  it "M4: below the floor the F_soft PRESUMPTION is zeroed (micro-channel deficit is quantization noise)" do
    raw = [ chatter("h0"), chatter("h1") ] # EIHC 2
    # V=40 < deficit_min_ccv=50 → a deficit would exist (40 − 2/0.02 = ... clamped) but is suppressed.
    sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 40, cell: cell, k: k, deficit_min_ccv: 50)
    expect(sb.f_soft).to eq(0.0)
    expect(sb.f_soft_lo).to eq(0.0)
    expect(sb.f_soft_hi).to eq(0.0)
    expect(sb.eihc).to eq(2.0)             # observability preserved (the low share is real)
    expect(sb.rho_obs).to be_within(1e-9).of(2 / 40.0)
  end

  it "M4: at/above the floor the deficit is UNCHANGED (a materially-online channel still accuses)" do
    raw = [ chatter("h0") ] # EIHC 1 → 1/0.03 ≈ 33 explains only 33 viewers → V=100 leaves a real deficit
    floored = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 100, cell: cell, k: k, deficit_min_ccv: 50)
    guardless = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 100, cell: cell, k: k)
    expect(floored.to_h).to eq(guardless.to_h) # V (100) > floor (50) → not below → deficit intact
    expect(floored.f_soft).to be > 0.0          # ≈ 100 − 1/0.03 = 67
  end

  it "M4: exactly AT the floor is not below (< not ≤) → deficit unchanged" do
    raw = [ chatter("h0") ]
    floored = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 50, cell: cell, k: k, deficit_min_ccv: 50)
    guardless = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 50, cell: cell, k: k)
    expect(floored.to_h).to eq(guardless.to_h) # V == floor → guard uses strict `<` → intact
  end

  it "M4: the floor uses the WINDOWED v_eff frame (min(V_W, V_inst)), not instant V" do
    raw = Array.new(30) { |i| chatter("h#{i}") }
    windowed = Set.new(raw.map(&:username))
    # instant V_inst=200 (above floor) but windowed V_W=40 → v_eff=min=40 < 50 → floored.
    sb = described_class.call(raw: raw, b_hard_usernames: Set.new, v: 200, cell: cell, k: k,
                              windowed_usernames: windowed, v_w: 40, deficit_min_ccv: 50)
    expect(sb.f_soft).to eq(0.0)
  end

  # G5 lurker-collapse "no-injection floor". Shared setup: 100 cumulative chatters, only 5 active in the
  # last 60min (windowed) — the collapsed-chat signature. flat cell rho_star 0.03.
  let(:g5_raw) { Array.new(100) { |i| chatter("h#{i}") } }
  let(:g5_windowed) { Set.new(Array.new(5) { |i| "h#{i}" }) }
  let(:g5_cell) { L2PresumeSpecDoubles::Cell.new(rho_star: 0.03, rho_lo: 0.03, rho_hi: 0.03) }

  it "G5 dormant (lurker_collapse_ratio ≤ 0) is byte-identical to the guardless windowed call" do
    guardless = described_class.call(raw: g5_raw, b_hard_usernames: Set.new, v: 2800, cell: g5_cell, k: k,
                                     windowed_usernames: g5_windowed, v_w: 2800)
    dormant = described_class.call(raw: g5_raw, b_hard_usernames: Set.new, v: 2800, cell: g5_cell, k: k,
                                   windowed_usernames: g5_windowed, v_w: 2800,
                                   own_ccv_baseline: 3000, lurker_collapse_ratio: -1.0)
    expect(dormant.to_h).to eq(guardless.to_h)
    expect(dormant.f_soft).to be_within(1.0).of(2800 - 5 / 0.03) # deficit intact (~2633) when guard off
  end

  it "G5 floors the deficit when the online is NOT elevated above the channel baseline (honest quieting)" do
    # V_eff 2800 ≤ baseline 3000 · (1 + 0.3) = 3900 → stable online, viewers just went quiet → no injection.
    sb = described_class.call(raw: g5_raw, b_hard_usernames: Set.new, v: 2800, cell: g5_cell, k: k,
                              windowed_usernames: g5_windowed, v_w: 2800,
                              own_ccv_baseline: 3000, lurker_collapse_ratio: 0.3)
    expect(sb.f_soft).to eq(0.0)
    expect(sb.f_soft_lo).to eq(0.0)
    expect(sb.f_soft_hi).to eq(0.0)
    expect(sb.rho_obs).to be_within(1e-6).of(5 / 2800.0) # ρ_obs preserved (the low share is real; only the presumption is suppressed)
  end

  it "G5 KEEPS the deficit when the online IS elevated above baseline (sustained injection)" do
    # V_eff 6000 > baseline 3000 · 1.3 = 3900 → online elevated → possible injection → deficit stands.
    sb = described_class.call(raw: g5_raw, b_hard_usernames: Set.new, v: 6000, cell: g5_cell, k: k,
                              windowed_usernames: g5_windowed, v_w: 6000,
                              own_ccv_baseline: 3000, lurker_collapse_ratio: 0.3)
    expect(sb.f_soft).to be_within(1.0).of(6000 - 5 / 0.03) # ≈ 5833 deficit preserved
  end

  it "G5 is inert in cumulative mode (v_w nil) even with a positive ratio — keys on the windowed frame only" do
    # Load-bearing (CR N1): use a THIN cumulative roster (5 chatters) so the cumulative deficit is POSITIVE
    # (2800 − 5/0.03 ≈ 2633). If the guard wrongly ignored the nil v_w and fired (2800 ≤ 3000·1.3), f_soft
    # would floor to 0 — a value that DIFFERS from the correct positive deficit. Asserting the positive
    # deficit proves the `v_w &&` short-circuit keeps G5 off in cumulative mode.
    thin = Array.new(5) { |i| chatter("h#{i}") }
    sb = described_class.call(raw: thin, b_hard_usernames: Set.new, v: 2800, cell: g5_cell, k: k,
                              own_ccv_baseline: 3000, lurker_collapse_ratio: 0.3) # v_w nil (cumulative)
    expect(sb.f_soft).to be_within(1.0).of(2800 - 5 / 0.03) # ≈2633 positive → guard did NOT floor
  end
end
