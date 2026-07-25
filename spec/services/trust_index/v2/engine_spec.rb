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
                        :own_ccv_baseline, :sustained_count, :ccv_cov, :pop_deficit_density)
  K = Data.define(:pi0, :tau_hard, :tau_delta, :phi_yellow, :phi_red, :q_mid, :q_hi,
                  :llr_temporal_r2, :llr_temporal_r3, :llr_temporal_r4, :llr_temporal_r7,
                  :llr_per_user_bot_score, :llr_known_bot, :i_event_enabled,
                  # TI v2.1 C_self^SP — dormant defaults (mirror Registry). Present so k.with(...) can flip
                  # them in the C_self^SP describe block; absent-key engine tests read them via respond_to?.
                  :csustained_enabled, :csustained_n_windows, :csustained_elevated_margin,
                  :csustained_cov_ceiling,
                  # TI v2.1 C_pop — dormant defaults (mirror Registry); k.with(...) flips them in the C_pop block.
                  :cpop_enabled, :cpop_n_windows, :cpop_density_frac, :cpop_elevated_margin).new(
                    pi0: 0.02, tau_hard: 0.9, tau_delta: 0.5, phi_yellow: 0.10, phi_red: 0.35,
                    q_mid: 0.5, q_hi: 0.8, llr_temporal_r2: 1.1, llr_temporal_r3: 2.2,
                    llr_temporal_r4: 2.9, llr_temporal_r7: 4.6, llr_per_user_bot_score: 3.9,
                    llr_known_bot: 3.4, i_event_enabled: 0.0, # DORMANT default (mirror Registry)
                    csustained_enabled: 0.0, csustained_n_windows: 999.0,
                    csustained_elevated_margin: 0.30, csustained_cov_ceiling: 0.0,
                    cpop_enabled: 0.0, cpop_n_windows: 999.0, cpop_density_frac: 999.0, cpop_elevated_margin: 0.30
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
             own_ccv_baseline: nil, sustained_count: 0, ccv_cov: nil, pop_deficit_density: 0.0 }
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
