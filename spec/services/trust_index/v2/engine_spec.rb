# frozen_string_literal: true

require "rails_helper"

module EngineSpecDoubles
  # A chatter carries BOTH the L0 LLR signals and the L2 EihcWeigher features + username.
  Chatter = Data.define(:username, :temporal_recurrence, :known_bot_hit, :per_user_bot_score,
                        :account_profile_llr, :anti_bot_llr,
                        :cluster_delta_k, :cluster_size, :age_gate, :recurrence_gate)
  Cell = Data.define(:rho_star, :rho_lo, :rho_hi, :calibrated, :rho_p1, :ccv_typical)
  Context = Data.define(:raw_chatters, :v, :cell, :rho_self_lo, :clean_self_history, :i_event,
                        :i_event_external, :raid_window, :n_chat_eff, :q, :cold_start_tier, :self_history_stable,
                        :chatter_quality_high, :stream_count, :unattributed_surge, :thin_sample,
                        :cps, :reputation, :ccv_chat_divergence, :l2_roster_usernames, :v_w,
                        :own_ccv_baseline, :sustained_count, :ccv_cov, :pop_deficit_density, :chatter_mc)
  K = Data.define(:pi0, :tau_hard, :tau_delta, :phi_yellow, :phi_red, :q_mid, :q_hi,
                  :llr_temporal_r2, :llr_temporal_r3, :llr_temporal_r4, :llr_temporal_r7,
                  :llr_per_user_bot_score, :llr_known_bot, :i_event_enabled,
                  # TI v2.1 C_self^SP — dormant defaults (mirror Registry). Present so k.with(...) can flip
                  # them in the C_self^SP describe block; absent-key engine tests read them via respond_to?.
                  :csustained_enabled, :csustained_n_windows, :csustained_elevated_margin,
                  :csustained_cov_ceiling,
                  # TI v2.1 C_pop — dormant defaults (mirror Registry); k.with(...) flips them in the C_pop block.
                  :cpop_enabled, :cpop_n_windows, :cpop_density_frac, :cpop_elevated_margin,
                  # FULL-CHAIN M4 shared deficit-family absolute floor — dormant default (mirror Registry);
                  # k.with(deficit_min_ccv: 50) flips it in the M4 describe block.
                  :deficit_min_ccv,
                  # FULL-CHAIN M3 c_hard hybrid integer named-count trigger — dormant defaults (mirror Registry);
                  # k.with(...) flips them in the M3 describe block. M3.1 mc-filter (chard_abs_mc_max) dormant 999.
                  :chard_abs_enabled, :chard_abs_count, :chard_abs_roster_min, :chard_abs_share, :chard_abs_mc_max).new(
                    pi0: 0.02, tau_hard: 0.9, tau_delta: 0.5, phi_yellow: 0.10, phi_red: 0.35,
                    q_mid: 0.5, q_hi: 0.8, llr_temporal_r2: 1.1, llr_temporal_r3: 2.2,
                    llr_temporal_r4: 2.9, llr_temporal_r7: 4.6, llr_per_user_bot_score: 3.9,
                    llr_known_bot: 3.4, i_event_enabled: 0.0, # DORMANT default (mirror Registry)
                    csustained_enabled: 0.0, csustained_n_windows: 999.0,
                    csustained_elevated_margin: 0.30, csustained_cov_ceiling: 0.0,
                    cpop_enabled: 0.0, cpop_n_windows: 999.0, cpop_density_frac: 999.0, cpop_elevated_margin: 0.30,
                    deficit_min_ccv: 0.0, # DORMANT default (mirror Registry)
                    chard_abs_enabled: 0.0, chard_abs_count: 999.0, chard_abs_roster_min: 999.0, chard_abs_share: 999.0,
                    chard_abs_mc_max: 999.0 # M3.1 dormant (mirror Registry — count all mc)
                  )
end

RSpec.describe TrustIndex::V2::Engine do
  let(:k) { EngineSpecDoubles::K }
  let(:cell) { EngineSpecDoubles::Cell.new(rho_star: 0.03, rho_lo: 0.02, rho_hi: 0.05, calibrated: true, rho_p1: nil, ccv_typical: nil) }

  def chatter(name, bot: false)
    EngineSpecDoubles::Chatter.new(
      username: name, temporal_recurrence: (bot ? 9 : nil), known_bot_hit: bot,
      per_user_bot_score: (bot ? 1.0 : nil), account_profile_llr: 0.0, anti_bot_llr: 0.0,
      cluster_delta_k: 0.0, cluster_size: 1, age_gate: 1.0, recurrence_gate: 1.0
    )
  end

  def context(chatters, **over)
    base = { raw_chatters: chatters, v: 5000, cell: cell, rho_self_lo: 0.03, clean_self_history: true,
             i_event: false, i_event_external: false, raid_window: false, n_chat_eff: chatters.size, q: 0.9,
             cold_start_tier: "full", self_history_stable: true, chatter_quality_high: true,
             stream_count: 20, unattributed_surge: false, thin_sample: false, cps: 70,
             reputation: "Стабильная", ccv_chat_divergence: 0.0, l2_roster_usernames: nil, v_w: nil,
             own_ccv_baseline: nil, sustained_count: 0, ccv_cov: nil, pop_deficit_density: 0.0, chatter_mc: {} }
    EngineSpecDoubles::Context.new(**base.merge(over))
  end

  it "runs L0→L4 end-to-end: a clean channel → high ERV, GREEN, authenticity ~100" do
    r = described_class.compute(context: context(Array.new(150) { |i| chatter("h#{i}") }, n_chat_eff: 150), k: k)
    expect(r.f_hard).to eq(0.0)                 # no named bots
    expect(r.erv).to be > 4900                  # almost all real (EIHC/ρ* explains V)
    expect(r.authenticity).to be > 95
    expect(r.band.color).to eq("green")
    expect(r.confirmed_anomaly).to be(false)
    expect(r.engine_version).to eq("v2")
  end

  it "flags a named-bot-heavy stream RED with a C_hard plashka" do
    chatters = Array.new(60) { |i| chatter("b#{i}", bot: true) } + Array.new(40) { |i| chatter("h#{i}") }
    r = described_class.compute(context: context(chatters, n_chat_eff: 100), k: k)
    expect(r.b_hard.size).to eq(60)             # 60 named ≥ τ_hard
    expect(r.n_frac).to be >= 0.35              # 60/100 → ≥ φ_red
    expect([ r.band.row, r.band.color ]).to eq([ 1, "red" ])
    expect(r.confirmed_anomaly).to be(true)
    expect(r.reason_codes.map(&:code)).to include("HARD_NAMED_FRACTION")
  end

  it "PR3a: exposes the additive soft breakdown + authenticity interval + Q (gap D-3, no logic change)" do
    r = described_class.compute(context: context(Array.new(150) { |i| chatter("h#{i}") }, n_chat_eff: 150), k: k)
    # f_soft is now surfaced (was folded into f_hat via L3 max); f_hat == max(f_hard, f_soft, f_self)
    expect(r.f_soft).not_to be_nil
    expect(r.f_hat).to eq([ r.f_hard, r.f_soft, r.f_self ].max)
    expect(r.f_soft_lo).to be <= r.f_soft
    expect(r.f_soft_hi).to be >= r.f_soft
    # authenticity interval brackets the point estimate (more fraud → lower bound)
    expect(r.authenticity_lo).to be <= r.authenticity
    expect(r.authenticity_hi).to be >= r.authenticity
    expect(r.q_score).to eq(0.9) # Q passthrough from context (helper sets q: 0.9)
  end

  it "P0.5: stamps rho_convention 'cumulative' by default, 'windowed' when co-windowed inputs present" do
    chatters = Array.new(150) { |i| chatter("h#{i}") }
    cumulative = described_class.compute(context: context(chatters, n_chat_eff: 150), k: k)
    expect(cumulative.rho_convention).to eq("cumulative") # v_w nil → dormant/instant frame
    windowed = described_class.compute(
      context: context(chatters, n_chat_eff: 150,
                       l2_roster_usernames: chatters.map(&:username).to_set, v_w: 4800),
      k: k
    )
    expect(windowed.rho_convention).to eq("windowed") # flag-ON co-windowed frame
  end

  it "G1: a decaying young stream (V_W > V_inst) keeps high authenticity — the stale median makes no false deficit" do
    chatters = Array.new(30) { |i| chatter("h#{i}") } # thin honest chat, EIHC 30
    # decay: current instant online V_inst=300, windowed median V_W=1500 is stale-high (early spike).
    # Uncapped V_W → f_soft = max(0, 1500 − 30/0.03) = 500 → F̂ 500 → authenticity clamps to 0 (FALSE hit).
    # G1 caps V at min(1500,300)=300 → f_soft = max(0, 300 − 1000) = 0 → authenticity stays ~100.
    r = described_class.compute(
      context: context(chatters, v: 300, n_chat_eff: 30,
                       l2_roster_usernames: chatters.map(&:username).to_set, v_w: 1500),
      k: k
    )
    expect(r.f_soft).to eq(0.0)
    expect(r.authenticity).to be > 90
    expect(r.band.color).not_to eq("red")
  end

  describe "i_event EPIC (C_self wiring) — dormant by default, fires only when enabled + fixture screams" do
    # "Screaming inflation" fixture: thin honest chat (EIHC≈30) but V=5000 → Deficit huge → rho_dropped [1]
    # true; the 5 external conjuncts pre-ANDed true (i_event_external); clean+stable self-history; no raid.
    def firing_ctx(**over)
      context(Array.new(30) { |i| chatter("h#{i}") }, v: 5000, n_chat_eff: 30,
              rho_self_lo: 0.03, clean_self_history: true, self_history_stable: true,
              i_event_external: true, raid_window: false, cold_start_tier: "full", **over)
    end

    it "red-team #4: K carries i_event_enabled present (the flip spec is load-bearing only if it does)" do
      expect(k.i_event_enabled).to eq(0.0)
      expect(k.with(i_event_enabled: 1.0).i_event_enabled).to eq(1.0)
    end

    it "DORMANT (enabled=0.0): i_event=false regardless of fixture → f_self=0, c_self=false, no accusation" do
      r = described_class.compute(context: firing_ctx, k: k)
      expect(r.c_self).to be(false)
      expect(r.f_self).to eq(0.0)
      expect(r.confirmed_anomaly).to be(false)
      expect([ 1, 2 ]).not_to include(r.band.row) # not an accusatory row (F_soft alone → AMBER row 6)
    end

    it "GOLDEN byte-identical: at enabled=0.0, i_event_external true vs false yield identical Results" do
      on  = described_class.compute(context: firing_ctx(i_event_external: true), k: k)
      off = described_class.compute(context: firing_ctx(i_event_external: false), k: k)
      expect(on.to_h).to eq(off.to_h) # the +i_event_external field is inert while dormant (read only in derive_i_event)
    end

    it "FLIP proves the wire is REAL: enabled=1.0 + screaming fixture → i_event fires → c_self, confirmed_anomaly, f_self>0, band≤2" do
      r = described_class.compute(context: firing_ctx, k: k.with(i_event_enabled: 1.0))
      expect(r.c_self).to be(true)
      expect(r.f_self).to be > 0
      expect(r.confirmed_anomaly).to be(true)
      expect(r.band.row).to be <= 2 # C_self corroborates → F_soft/F_self escalate past AMBER
    end

    it "FLIP still safe with NO baseline: enabled=1.0 but self_history_stable=false → rho_dropped [1] false → i_event false" do
      r = described_class.compute(context: firing_ctx(self_history_stable: false), k: k.with(i_event_enabled: 1.0))
      expect(r.c_self).to be(false)
      expect(r.f_self).to eq(0.0)
    end

    it "FLIP suppressed by raid: enabled=1.0 + screaming fixture but raid_window=true → i_event false (provenance)" do
      r = described_class.compute(context: firing_ctx(raid_window: true), k: k.with(i_event_enabled: 1.0))
      expect(r.c_self).to be(false)
    end
  end

  describe "C_self^SP sustained-plateau arm (T1-074, battle-mode) — dormant by default, YELLOW-capped when flipped" do
    # HELD-plateau fixture: thin honest chat (EIHC≈30) but V=5000 held high → rho_dropped [1]; online
    # elevated vs the own baseline (100) → [P2]; flat CCV (ccv_cov 0.01) → [P3]; a long persisted run
    # (sustained_count 5) → durability; clean+stable self-history; no raid/surge; full tier.
    def plateau_ctx(**over)
      context(Array.new(30) { |i| chatter("h#{i}") }, v: 5000, n_chat_eff: 30,
              rho_self_lo: 0.03, clean_self_history: true, self_history_stable: true,
              cold_start_tier: "full", raid_window: false, unattributed_surge: false,
              own_ccv_baseline: 100, ccv_cov: 0.01, sustained_count: 5, **over)
    end

    let(:k_on) do
      k.with(csustained_enabled: 1.0, csustained_n_windows: 3.0,
             csustained_cov_ceiling: 0.05, csustained_elevated_margin: 0.30)
    end

    it "DORMANT (csustained_enabled=0.0): the held-plateau fixture does NOT accuse → F_soft alone → AMBER" do
      r = described_class.compute(context: plateau_ctx, k: k)
      expect(r.c_self).to be(false)
      expect(r.confirmed_anomaly).to be(false)
      expect([ 1, 2 ]).not_to include(r.band.row) # a soft deficit alone → AMBER row 6
    end

    it "GOLDEN byte-identical at defaults: sustained_count 0 vs 99 yield identical Results while dormant" do
      lo = described_class.compute(context: plateau_ctx(sustained_count: 0), k: k)
      hi = described_class.compute(context: plateau_ctx(sustained_count: 99), k: k)
      expect(lo.to_h).to eq(hi.to_h) # sustained_count/ccv_cov inert while csustained_enabled=0.0
    end

    it "FLIP proves the wire is REAL: enabled + held plateau → i_event fires, c_self, YELLOW (capped, no independent corroborator)" do
      r = described_class.compute(context: plateau_ctx, k: k_on)
      expect(r.c_self).to be(true)
      expect(r.confirmed_anomaly).to be(true)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ]) # sustained-only caps at YELLOW, never public RED alone
      expect(r.reason_codes.map(&:code)).to include("SELF_HISTORY_SUSTAINED_INFLATION")
    end

    it "FP guard (baseline): no honest baseline (self_history_stable false) → no fire even when enabled" do
      expect(described_class.compute(context: plateau_ctx(self_history_stable: false), k: k_on).c_self).to be(false)
    end

    it "FP guard [P2]: online NOT elevated vs own baseline (honest quieting) → no fire (G5-inverse)" do
      # own_ccv_baseline 6000 > V 5000 → not elevated → the sustained arm is off; the honest quiet-chat case
      # (chat collapses, online stable) — F_soft is separately floored by G5 in L2.
      expect(described_class.compute(context: plateau_ctx(own_ccv_baseline: 6000), k: k_on).c_self).to be(false)
    end

    it "FP guard [P3]: a RISING surge (high CoV, not flat) → plateau_shape false → no fire" do
      expect(described_class.compute(context: plateau_ctx(ccv_cov: 0.40), k: k_on).c_self).to be(false)
    end

    it "FP guard (durability): a short run (sustained_count+1 < N) → no fire yet" do
      expect(described_class.compute(context: plateau_ctx(sustained_count: 1), k: k_on).c_self).to be(false)
    end

    it "FP guard [P4] raid: a raid window suppresses the sustained arm (provenance)" do
      expect(described_class.compute(context: plateau_ctx(raid_window: true), k: k_on).c_self).to be(false)
    end
  end

  describe "C_pop population-anchored arm (silent always-botter fix) — dormant by default, YELLOW-capped when flipped" do
    def cal_cell(**over)
      EngineSpecDoubles::Cell.new(**{ rho_star: 0.10, rho_lo: 0.06, rho_hi: 0.15, calibrated: true,
                                      rho_p1: 0.04, ccv_typical: 200 }.merge(over))
    end
    # Silent always-botter: V botted-high (1000), thin honest chat (EIHC≈30 → rho_obs≈0.03 < rho_p1 0.04),
    # online INFLATED vs cell-typical (1000 ≫ 200), persistent (density 1.0), full tier, NO honest history
    # (self-arm dead — the de-poison would leave its baseline empty). The channel C_hard/C_self/C_inflation
    # all miss; only C_pop (the population reference) can accuse it.
    def botter_ctx(**over)
      context(Array.new(30) { |i| chatter("h#{i}") }, v: 1000, n_chat_eff: 30, cell: cal_cell,
              cold_start_tier: "full", raid_window: false, unattributed_surge: false,
              pop_deficit_density: 1.0, self_history_stable: false, clean_self_history: false, **over)
    end
    let(:k_pop) { k.with(cpop_enabled: 1.0, cpop_density_frac: 0.8, cpop_n_windows: 10, cpop_elevated_margin: 0.30) }

    it "DORMANT (cpop_enabled=0.0): the always-botter reads AMBER (F_soft alone, uncorroborated) — THE GAP" do
      r = described_class.compute(context: botter_ctx, k: k)
      expect(r.confirmed_anomaly).to be(false)
      expect([ 1, 2 ]).not_to include(r.band.row)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end

    it "GOLDEN byte-identical: pop_deficit_density 0.0 vs 1.0 yield identical Results while dormant" do
      lo = described_class.compute(context: botter_ctx(pop_deficit_density: 0.0), k: k)
      hi = described_class.compute(context: botter_ctx(pop_deficit_density: 1.0), k: k)
      expect(lo.to_h).to eq(hi.to_h)
    end

    it "FLIP: enabled + always-botter → C_pop fires → YELLOW + POPULATION_CHAT_DEFICIT (AMBER trap broken)" do
      r = described_class.compute(context: botter_ctx, k: k_pop)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ])
      expect(r.confirmed_anomaly).to be(true)
      expect(r.reason_codes.map(&:code)).to include("POPULATION_CHAT_DEFICIT")
    end

    it "FP guard: an UNCALIBRATED cell → no C_pop accusation (never off DEFAULT ρ*)" do
      r = described_class.compute(context: botter_ctx(cell: cal_cell(calibrated: false)), k: k_pop)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end

    it "FP guard [5]: online NOT elevated vs cell-typical (honest low-chat channel) → no C_pop" do
      r = described_class.compute(context: botter_ctx(cell: cal_cell(ccv_typical: 5000)), k: k_pop)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end

    it "FP guard: rho_p1 NULL (un-reseeded cell) → no C_pop" do
      r = described_class.compute(context: botter_ctx(cell: cal_cell(rho_p1: nil)), k: k_pop)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end

    it "FP guard [4]: rho_obs NOT below the P1 tail (chats normally for its cell) → no C_pop" do
      r = described_class.compute(context: botter_ctx(cell: cal_cell(rho_p1: 0.01)), k: k_pop)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end

    it "FP guard [6]: not persistent (density < frac) → no C_pop" do
      r = described_class.compute(context: botter_ctx(pop_deficit_density: 0.5), k: k_pop)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end

    it "FP guard: a raid window suppresses C_pop (provenance)" do
      r = described_class.compute(context: botter_ctx(raid_window: true), k: k_pop)
      expect(r.reason_codes.map(&:code)).not_to include("POPULATION_CHAT_DEFICIT")
    end
  end

  describe "FULL-CHAIN M4 shared deficit-family floor (deficit_min_ccv) — dormant by default, FP-only suppressor" do
    # A MICRO held-plateau that WOULD trip C_self^SP: V=40, own baseline 1 (40 ≫ 1·1.3 → elevated),
    # thin chat EIHC 30 vs rho_self_lo 0.90 → rho_dropped (40 − 30/0.9 ≈ 6.7 > 0), flat CoV, long run.
    # This is the tremortela ccv=2 nonsense-FP class writ small — real online is immaterial.
    def micro_ctx(**over)
      context(Array.new(30) { |i| chatter("h#{i}") }, v: 40, n_chat_eff: 30,
              rho_self_lo: 0.90, clean_self_history: true, self_history_stable: true,
              cold_start_tier: "full", raid_window: false, unattributed_surge: false,
              own_ccv_baseline: 1, ccv_cov: 0.01, sustained_count: 5, **over)
    end
    let(:k_sus) do
      k.with(csustained_enabled: 1.0, csustained_n_windows: 3.0,
             csustained_cov_ceiling: 0.05, csustained_elevated_margin: 0.30)
    end

    it "GOLDEN byte-identical: deficit_min_ccv 0.0 is a no-op (matches the keyless-default behavior)" do
      base = described_class.compute(context: micro_ctx, k: k_sus)                       # C_self^SP fires (micro)
      zero = described_class.compute(context: micro_ctx, k: k_sus.with(deficit_min_ccv: 0.0))
      expect(zero.to_h).to eq(base.to_h)
    end

    it "with the floor (50) the micro C_self^SP is SUPPRESSED — no nonsense accusation on an immaterial online" do
      fired = described_class.compute(context: micro_ctx, k: k_sus)                      # floor 0.0 → fires
      floored = described_class.compute(context: micro_ctx, k: k_sus.with(deficit_min_ccv: 50))
      expect(fired.c_self).to be(true)                                                   # proves the fixture WOULD accuse
      expect(floored.c_self).to be(false)                                               # M4 floors [P2] online_elevated? + F_self
      expect([ 1, 2 ]).not_to include(floored.band.row)                                 # not accusatory
    end

    it "the floor does NOT touch a materially-online botter (V above the floor still accuses)" do
      # Same plateau shape but V=5000 (≫ floor) with own baseline 100 → still elevated → C_self^SP intact.
      big = context(Array.new(30) { |i| chatter("h#{i}") }, v: 5000, n_chat_eff: 30,
                    rho_self_lo: 0.03, clean_self_history: true, self_history_stable: true,
                    cold_start_tier: "full", own_ccv_baseline: 100, ccv_cov: 0.01, sustained_count: 5)
      r = described_class.compute(context: big, k: k_sus.with(deficit_min_ccv: 50))
      expect(r.c_self).to be(true)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ])
    end

    it "floors F_soft too: a micro channel's soft deficit is zeroed at/below the floor (L2 wiring)" do
      # High-ρ cell so a deficit EXISTS pre-floor at micro V (EIHC 30 / ρ_lo 0.9 = 33 < V=40 → f_soft_lo ≈ 7).
      hi_cell = EngineSpecDoubles::Cell.new(rho_star: 0.9, rho_lo: 0.9, rho_hi: 0.9, calibrated: true, rho_p1: nil, ccv_typical: nil)
      base = micro_ctx(cell: hi_cell, rho_self_lo: nil, clean_self_history: false)
      pre = described_class.compute(context: base, k: k)                       # floor off → deficit present
      floored = described_class.compute(context: base, k: k.with(deficit_min_ccv: 50))
      expect(pre.f_soft_lo).to be > 0.0                                        # proves the deficit exists without the floor
      expect(floored.f_soft_lo).to eq(0.0)                                    # M4 floors it (V=40 < 50)
    end
  end

  describe "FULL-CHAIN M3 c_hard hybrid (c_hard_abs) — dormant by default, YELLOW-only integer trigger" do
    # A mid-roster confirmed-bot cluster the P5-diluted fraction path misses: 5 named bots + 45 humans
    # (roster 50). n_frac = f_hard_lo(P5≈4.5)/50 ≈ 0.09 < φ_yellow 0.10 → the fraction path is GREEN, but
    # the INTEGER count (5 ≥ 3, roster 50 ≥ 30, share 0.10 ≥ 0.02) fires c_hard_abs.
    def cluster_ctx(**over)
      chatters = Array.new(5) { |i| chatter("b#{i}", bot: true) } + Array.new(45) { |i| chatter("h#{i}") }
      # V=1000 so the 45 humans (EIHC 45 / ρ* 0.03 = 1500) fully explain the online → NO F_soft deficit;
      # the ONLY signal left is the 5-named integer cluster. Isolates c_hard_abs from the deficit family.
      context(chatters, v: 1000, n_chat_eff: 50, cold_start_tier: "full", **over)
    end
    let(:k_abs) { k.with(chard_abs_enabled: 1.0, chard_abs_count: 3.0, chard_abs_roster_min: 30.0, chard_abs_share: 0.02) }

    it "DORMANT (chard_abs_enabled=0.0): the mid-roster cluster reads GREEN (fraction path P5-diluted below φ_yellow)" do
      r = described_class.compute(context: cluster_ctx, k: k)
      expect(r.n_frac).to be < k.phi_yellow          # the fraction path is dead
      expect(r.band.row).to be > 2                    # → GREEN (the gap)
      expect(r.confirmed_anomaly).to be(false)
    end

    it "GOLDEN byte-identical: chard_abs_count 999 vs 3 is inert while enabled=0.0" do
      lo = described_class.compute(context: cluster_ctx, k: k)
      hi = described_class.compute(context: cluster_ctx, k: k.with(chard_abs_count: 3.0)) # enabled still 0.0
      expect(lo.to_h).to eq(hi.to_h)
    end

    it "FLIP: enabled + 5 named of 50 → row2 YELLOW + plashka + HARD_NAMED_FRACTION (the cluster is now caught)" do
      r = described_class.compute(context: cluster_ctx, k: k_abs)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ])
      expect(r.confirmed_anomaly).to be(true)
      expect(r.reason_codes.map(&:code)).to include("HARD_NAMED_FRACTION")
    end

    it "B2: c_hard_abs is YELLOW-ONLY — a coincident f_soft deficit does NOT escalate it to public RED" do
      # A big deficit AND the integer trigger → still YELLOW (c_hard_abs excluded from independently_corroborated?).
      r = described_class.compute(context: cluster_ctx(v: 5000, cell: EngineSpecDoubles::Cell.new(
        rho_star: 0.9, rho_lo: 0.9, rho_hi: 0.9, calibrated: true, rho_p1: nil, ccv_typical: nil)), k: k_abs)
      expect(r.band.row).to eq(2) # never row1 off an absolute count + deficit
    end

    it "FP guard (tier): a BASIC-tier channel with the cluster is NOT accused" do
      r = described_class.compute(context: cluster_ctx(cold_start_tier: "basic"), k: k_abs)
      expect(r.band.row).to be > 2
    end

    # FULL-CHAIN M3.1 mc-filter — count only DEDICATED (mc ≤ chard_abs_mc_max) named members.
    it "M3.1 DORMANT (mc_max 999): chatter_mc is inert → dedicated count == full named → fires as before" do
      # 5 named, 2 of them roaming (mc=20); at the dormant mc_max 999 all 5 count → YELLOW (byte-identical to M3).
      mc = { "b0" => 3, "b1" => 3, "b2" => 3, "b3" => 20, "b4" => 20 }
      r = described_class.compute(context: cluster_ctx(chatter_mc: mc), k: k_abs)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ])
    end

    it "M3.1 mc-filter ON: roaming (mc≥15) named members are EXCLUDED → a roaming-heavy cluster does NOT accuse" do
      # Same 5 named but only 3 dedicated (mc=3) + 2 roaming (mc=20). At mc_max=8, count 5→3 < chard_abs_count 5.
      mc = { "b0" => 3, "b1" => 3, "b2" => 3, "b3" => 20, "b4" => 20 }
      k5 = k.with(chard_abs_enabled: 1.0, chard_abs_count: 5.0, chard_abs_roster_min: 30.0, chard_abs_share: 0.02, chard_abs_mc_max: 8.0)
      r = described_class.compute(context: cluster_ctx(chatter_mc: mc), k: k5)
      expect(r.band.row).to be > 2 # 3 dedicated < 5 required → not accused (roaming spam can't lift the count)
    end

    it "M3.1 mc-filter keeps a genuine DEDICATED botnet (all mc=3) accused" do
      mc = { "b0" => 3, "b1" => 3, "b2" => 3, "b3" => 3, "b4" => 3 }
      k5 = k.with(chard_abs_enabled: 1.0, chard_abs_count: 5.0, chard_abs_roster_min: 30.0, chard_abs_share: 0.02, chard_abs_mc_max: 8.0)
      r = described_class.compute(context: cluster_ctx(chatter_mc: mc), k: k5)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ]) # 5 dedicated ≥ 5 → still caught
    end

    it "M3.1: a named member with NO temporal mc (nil, e.g. known_bot) counts as dedicated" do
      # empty chatter_mc → all 5 named have nil mc → count as dedicated → fires at mc_max=8.
      k5 = k.with(chard_abs_enabled: 1.0, chard_abs_count: 5.0, chard_abs_roster_min: 30.0, chard_abs_share: 0.02, chard_abs_mc_max: 8.0)
      r = described_class.compute(context: cluster_ctx(chatter_mc: {}), k: k5)
      expect([ r.band.row, r.band.color ]).to eq([ 2, "yellow" ])
    end
  end

  describe "two-EIHC display split (recurrence_gate) — public authenticity UNGATED, accusation GATED" do
    # 40 first-time-here chatters (recurrence_gate 0.5), V=1000, cell ρ*=0.03.
    #   ungated EIHC = 40 → 40/1000 = 0.04 ≥ ρ* → NO display deficit → authenticity 100 (protected)
    #   gated   EIHC = 20 → 20/1000 = 0.02 < ρ* → f_soft ≈ 333 (the accusation basis — the deficit is seen)
    it "downweighted chatters lower the GATED deficit (f_soft) but NOT the DISPLAY authenticity/ERV" do
      chatters = Array.new(40) { |i| chatter("h#{i}").with(recurrence_gate: 0.5) }
      r = described_class.compute(context: context(chatters, v: 1000, n_chat_eff: 40), k: k)
      expect(r.authenticity).to eq(100.0)       # DISPLAY (ungated) — the public number is protected
      expect(r.erv).to eq(1000.0)               # DISPLAY erv = V (no display-basis fraud)
      expect(r.eihc).to be_within(0.5).of(20.0) # GATED EIHC = 0.5 × 40 (persisted/accusation basis)
      expect(r.f_soft).to be > 300              # GATED — the accusation re-sees the deficit the gate restored
    end

    it "dormant (recurrence_gate 1.0): no split — display == accusation basis (byte-identical path)" do
      chatters = Array.new(40) { |i| chatter("h#{i}") } # recurrence_gate defaults to 1.0
      r = described_class.compute(context: context(chatters, v: 1000, n_chat_eff: 40), k: k)
      expect(r.eihc).to be_within(0.5).of(40.0) # ungated == gated → EIHC = 40
      expect(r.authenticity).to eq(100.0)       # 40/1000 = 0.04 ≥ ρ* → no deficit either basis
      expect(r.f_soft).to eq(0.0)               # no gated deficit (vs 333 in the split case above)
    end
  end

  it "EC-15/TC-017: V≤0 (null CCV) short-circuits to GREY with null ERV — never a headline number" do
    r = described_class.compute(context: context([ chatter("a") ], v: 0, n_chat_eff: 0), k: k)
    expect(r.erv).to be_nil
    expect(r.authenticity).to be_nil
    expect(r.band.color).to eq("grey")
    expect(r.confirmed_anomaly).to be(false)
    expect(r.reason_codes.map(&:code)).to eq([ "WIDE_INTERVAL_THIN_SAMPLE" ])
    expect(r.to_headline_payload[:erv]).to be_nil
  end

  it "to_headline_payload emits the engine-agnostic publish contract (DEC-7)" do
    r = described_class.compute(context: context([ chatter("a") ], n_chat_eff: 1), k: k)
    payload = r.to_headline_payload
    expect(payload.keys).to include(:erv, :erv_interval, :axes, :band, :reason_codes,
                                    :confirmed_anomaly, :cold_start_tier, :confidence_marker, :engine_version)
    expect(payload[:erv_interval].keys).to contain_exactly(:lo, :hi)
    expect(payload[:engine_version]).to eq("v2")
  end
end
