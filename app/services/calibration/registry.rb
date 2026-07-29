# frozen_string_literal: true

module Calibration
  # Loads the TI v2 engine's scalar calibration constants from the DB (CalibrationConstant) into a
  # single immutable `k` object that L0→L4 read (SRS FR-016, ADR DEC-3/DEC-6). Values are ILLUSTRATIVE
  # until GATE 0; a missing key falls back to the illustrative default so a half-seeded env degrades,
  # not crashes. One query per load. (Per-cell ρ* baselines are read separately by CellResolver.)
  class Registry
    ILLUSTRATIVE = {
      pi0: 0.02, tau_hard: 0.90, tau_delta: 0.05,
      phi_yellow: 0.10, phi_red: 0.35, q_mid: 0.50, q_hi: 0.80,
      llr_temporal_r2: 1.10, llr_temporal_r3: 2.20, llr_temporal_r4: 2.90, llr_temporal_r7: 4.60,
      llr_per_user_bot_score: 3.90, llr_known_bot: 3.40,
      # TI v2.1 inflation-event corroborator (BUG-A/BUG-B pivot, 2026-07-22). Gives F_soft's
      # silent-viewbot deficit an INDEPENDENT second corroborator (C_inflation) so it can escalate
      # AMBER→YELLOW/RED, breaking the C_hard monoculture. Driven by the calibrated v1
      # CcvChatCorrelation signal (CCV↑ ∧ chat-flat = silent injection — CCV-shape, names nobody).
      # phi_inflation = CcvChatCorrelation value threshold. inflation_corrob_enabled is a bool-as-float
      # kill-switch: 0.0 (DEFAULT, DORMANT) → C_inflation never fires → band table byte-identical to
      # today. The PO-gated flip (after BUG-A lands + phi_inflation calibrated on the honest-anchor
      # firing rate) is a data update (set enabled→1.0), no redeploy (ADR DEC-3).
      phi_inflation: 0.30, inflation_corrob_enabled: 0.0,
      # TI v2.1 i_event self-history tripwire (C_self / F_self arm — the SECOND independent corroborator,
      # G-monoculture fix, T1-074 i_event EPIC 2026-07-23). i_event_enabled is a bool-as-float kill-switch:
      # 0.0 (DEFAULT, DORMANT) => engine derive_i_event returns false before reading any ie_* input =>
      # i_event=false everywhere => corroborated?, F_self eligibility, band rows all byte-identical to today.
      # The 4 ie_* floors gate external conjuncts [2/4/5/6]. Primary dormancy is the i_event_enabled=0.0
      # gate. The accidental-early-flip BACKSTOP (i_event cannot accuse before honest-corpus calibration
      # writes real floors) rests on [4] chat-share and [6] CoV being UNCONDITIONALLY non-negative → both
      # < their 0.0 defaults is impossible → the [2]∧[4]∧[5]∧[6] AND can never be true at defaults. [2]'s
      # z=99 is also never-fire (a MAD>0 guard makes 99·MAD unreachable); [5]'s -1.0 is recall-permissive
      # (a follower-crash could cross it) but [4]/[6] block the AND regardless. ⚠ Do NOT calibrate a
      # positive [4] (ie_arrival_floor_frac) or [6] (ie_cv_floor) floor BEFORE [2]/[5] — that lifts the
      # backstop. PO-gated flip (after the BUG-A windowing flip + honest-FP=0 calibration) = data update
      # (enabled=>1.0), no redeploy (DEC-3).
      i_event_enabled: 0.0,
      ie_v_trend_z: 99.0, ie_arrival_floor_frac: 0.0, ie_conv_floor: -1.0, ie_cv_floor: 0.0,
      # G5 (lurker-collapse "no-injection floor", battle-mode 2026-07-25). ONLY active co-windowed
      # (ti_v2_cowindowed_rho): an honest stream whose viewers stopped typing (music/ASMR/watch-party)
      # collapses windowed EIHC with a STABLE online → false F_soft deficit. The guard floors the deficit
      # when the online is NOT elevated above the channel's own honest CCV baseline (no injection to
      # presume). lurker_collapse_ratio = the elevation margin: floor when V ≤ baseline·(1+ratio). DEFAULT
      # -1.0 = DORMANT (L2Presume treats ≤0 as OFF → byte-identical). Calibrated positive (≈0.2-0.3) on a
      # silent-lurker honest cohort BEFORE the windowing flip so honest quiet streams read GREEN while a
      # sustained botter (online elevated vs baseline) keeps its deficit.
      lurker_collapse_ratio: -1.0,
      # TI v2.1 C_self^SP (Sustained-Plateau self-corroborator, battle-mode 2026-07-25). The legacy 6-AND
      # i_event is a STEP detector — it dies at a SUSTAINED plateau ([2] v-surge robust-z→0 once the
      # injection is held, [5] follower-conv confounded by co-arriving real humans). C_self^SP adds a
      # durable OR-arm that catches a HELD silent-viewbot plateau: a flat-and-high CCV (plateau_shape [P3])
      # + a persistent windowed chat-share deficit (rho_dropped [P1]) at an online held above the channel's
      # own honest baseline (G5-inverse [P2]), sustained over N consecutive TIH windows. A sustained-ONLY
      # fire caps at YELLOW (row2 — single deficit-family signal); public RED needs a second INDEPENDENT
      # corroborator (C_hard/C_inflation). csustained_enabled is a bool-as-float kill-switch: 0.0 (DEFAULT,
      # DORMANT) → engine sustained_plateau? returns false BEFORE any TIH/CoV read → i_event byte-identical
      # to the legacy arm alone (golden spec). DEFENSE-IN-DEPTH backstops (the arm cannot accuse even if
      # enabled is flipped early, before calibration writes real values): csustained_n_windows=999
      # (sustained_count clamps ≤60 → +1 never reaches 999) AND csustained_cov_ceiling=0.0 (CoV ≥ 0 is
      # never < 0 → plateau_shape? never true). ⚠ Do NOT calibrate a positive cov_ceiling before N is set,
      # or that backstop lifts. Calibrated on the WINDOWED convention (dariya labeled-positive plateau CoV
      # 0.014-0.017 vs honest-cohort p10 0.031) → PO-gated flip = data update (enabled=>1.0), no redeploy.
      csustained_enabled: 0.0,
      csustained_n_windows: 999.0,
      csustained_elevated_margin: 0.30,
      csustained_cov_ceiling: 0.0,
      # TI v2.1 C_pop (population-anchored F_soft accusation — the SILENT ALWAYS-BOTTER fix, 2026-07-25).
      # C_hard/C_self/C_inflation are all CHANNEL-referential (named bots in its chat / an inflation step
      # in its own history / a CCV-step in its stream) → a silent always-botter defeats all three by
      # construction (no names, no honest history [the de-poison leaves it EMPTY], no step) → it reads
      # AMBER 6b forever, never accused. C_pop closes that structural "F_soft can never self-accuse" hole:
      # the CALIBRATED cell ρ* is the un-poisonable HONEST chat-share of the channel's PEER POPULATION — a
      # persistent chat-share below the cell's P1 tail (rho_p1), with online INFLATED vs the cell-typical
      # (population_elevated?, the discriminator that separates a botter from an honest low-chat channel),
      # sustained at density ≥ frac, IS accusable off the population reference (not deficit-corroborating-
      # deficit — the population + time axes are orthogonal to the channel's own data; a farm can't launder
      # ρ*). Capped at YELLOW (population-alone never public RED — see band_classifier). csustained_enabled
      # mirror: cpop_enabled=0.0 (DORMANT kill-switch) → pop_corroborated? short-circuits before any read →
      # byte-identical. DEFENSE-IN-DEPTH backstops (un-fireable even if enabled flips early, before calib):
      # cpop_density_frac=999 (a density fraction ≥1.0 is unreachable) AND cpop_n_windows=999 (clamp≤60 →
      # +1 never reaches 999); ALSO rho_p1/ccv_typical are NULL on every cell until the re-seed writes them
      # (a third dormancy gate). ⚠ Calibrate rho_p1+ccv_typical+density_frac+n_windows+elevated_margin
      # TOGETHER (never one-before-others) or the backstop lifts. PO-gated flip = data update (no redeploy),
      # HARD-blocked on the ρ* re-seed at n≥150 (rho_p1 is noise below that) + EIHC anti-gaming gates live.
      cpop_enabled: 0.0,
      cpop_n_windows: 999.0,
      cpop_density_frac: 999.0,
      cpop_elevated_margin: 0.30,
      # FULL-CHAIN M3 c_hard hybrid (integer named-count trigger, 2026-07-27). The n_frac fraction path is
      # P5-diluted (one named bot → f_hard_lo P5 ≈ 0 → n_frac ≈ 0) and fraction-gated (needs ≥φ_yellow of the
      # WHOLE roster) → a mid-roster cluster of 3-10 confirmed cross-channel bots reads GREEN (live: anastaze
      # 15.9% R7-overlap → n_frac 0.064 → green). c_hard_abs adds a YELLOW trigger on the INTEGER count of
      # publicly-named (B_hard, ≥99%-precision) members: named_count ≥ chard_abs_count ∧ roster ≥
      # chard_abs_roster_min ∧ named/roster ≥ chard_abs_share. Naming legality is UNCHANGED (only B_hard
      # members are ever named). B2 (red-team): this is YELLOW-ONLY — it does NOT enter
      # independently_corroborated? (3 campaign roamers + a deficit must never reach public RED); the n_frac
      # fraction path keeps the RED bar (φ_red). chard_abs_enabled is the primary bool-as-float kill-switch:
      # 0.0 (DEFAULT, DORMANT) → c_hard_abs false before any read → band byte-identical. DEFENSE-IN-DEPTH
      # backstops (un-fireable even if enabled flips early): chard_abs_count=999 (a named count of a ≤500
      # roster can't reach 999) ∧ chard_abs_roster_min=999 ∧ chard_abs_share=999 (a share ≤1.0 < 999). ⚠
      # Calibrate count+roster_min+share TOGETHER (never one-before-others) or a backstop lifts. Calibrated
      # targets (M3, honest-anchor confirmed-present p99): count=max(3, p99+2)→3, roster_min=30, share=0.02.
      # PO-gated flip (accusatory) = data update, no redeploy.
      chard_abs_enabled: 0.0,
      chard_abs_count: 999.0,
      chard_abs_roster_min: 999.0,
      chard_abs_share: 999.0,
      # FULL-CHAIN M3.1 mc-filter (scale-immunity, 2026-07-29). c_hard_abs counts publicly-named (B_hard)
      # members; a member could be a ROAMING spam bot (max_concurrent_channels ≥ 15 — visits hundreds of
      # channels) whose presence does NOT mean the streamer bought it. The calibration (mc-signature) proved
      # the dedicated botnet sits at mc=EXACTLY-3 (rotate-3-channels, R∈[70,170]); roaming utility/spam sits
      # at mc≥15. chard_abs_mc_max caps the max_concurrent a named member may have to COUNT toward c_hard_abs
      # — so a big honest channel that attracts roaming spam at scale can't be false-accused off a roaming
      # count. DORMANT/byte-identical: 999.0 (DEFAULT) → every realistic mc ≤ 999 → the dedicated count ==
      # the full named count == today's live c_hard_abs. A member with NO temporal mc (e.g. a known_bot not
      # cross-channel-flagged) counts (mc nil → dedicated) — it's a named bot regardless. Calibrated flip
      # value ≈ 8 (keeps mc=3-6 dedicated botnets, excludes mc≥15 roaming). PO-gated data update (no redeploy).
      chard_abs_mc_max: 999.0,
      # TI v2.1 deficit_min_ccv (FULL-CHAIN M4, shared deficit-family absolute floor, 2026-07-27). Every
      # deficit-family accusation (F_soft label, F_self eligibility, C_self^SP [P2] online_elevated,
      # C_pop) rests on a per-viewer chat-share statistic that becomes integer-quantization NOISE below
      # ~50 concurrent viewers: at ρ*≈0.05, V=40 → E[chatters]≈2 → P(0 honest chatters in a window)≈13% →
      # a deficit PRESUMPTION has a double-digit false base-rate; and the C_self^SP "×(1+margin) relative
      # elevation" test is meaningless at V=2 (baseline 1 → threshold 1.3 → V=2 reads "elevated" — the
      # tremortela ccv=2 nonsense-FP). ONE shared floor (the failure semantic is identical everywhere;
      # per-arm values = fake precision), applied at each arm's OWN V-frame. DORMANT: 0.0 → every
      # `v < deficit_min_ccv` guard is `v < 0` = false → byte-identical (golden spec). This constant only
      # REMOVES accusations → no honest-FP path; recall cost = a botter buying <50 total online (below every
      # commercial bot tier, below product materiality) — accepted. Calibrated target 50 = half the smallest
      # commercial tier (100, CcvTierClustering KNOWN_TIERS); PO-gated data-flip (no redeploy), FIRST flip in
      # the FULL-CHAIN order (pure FP-reduction, lands before any aggression increase). ⚠ Do NOT raise past
      # ~50 — it is the only net under the stagger-evasion hole (temporal family evadable by ≤2-channel /
      # >5s-spaced posting → deficit family is the silent-bot backstop).
      deficit_min_ccv: 0.0,
      # TI v2.1 recurrence_gate (EIHC anti-gaming, 2026-07-25). EIHC = Σ_u weight(u); a chatting bot L0
      # misses (this-channel-only → low cross-channel temporal_recurrence → not b_hard) counts FULL weight
      # → lifts EIHC 1:1 → rho_obs rises above ρ* → the deficit vanishes → evades F_soft/C_self^SP[P1]/C_pop.
      # recurrence_gate downweights a chatter by WITHIN-channel loyalty s(u) = distinct past streams of THIS
      # channel they posted in (a first-time-here chatter s=0 = injection candidate → floored to g_new; a
      # regular s≥r_full = full weight). weight ramp [g_new,1] over [0,r_full]. DORMANT: recurrence_gate_
      # enabled=0.0 → the builder issues NO CH query (rec_map={}) AND the ramp returns 1.0 unconditionally at
      # the neutral defaults (r_full=1.0 ∧ new_floor=1.0) → EIHC byte-identical. Two-layer dormancy (query-
      # skip + value-1.0). ⚠ Calibrate r_full+new_floor TOGETHER (never one-before-others) or the backstop
      # lifts. age_gate is DEFERRED INDEFINITELY (per-chatter Helix infeasible at scale + re-imports the
      # ~52%-honest account_profile mass-FP; the only affordable newness signal IS recurrence_gate s=0).
      # FLIP HARD-blocked on: the two-EIHC display split (else a floored honest EIHC drops the PUBLIC
      # authenticity number — the account_profile leak through the EIHC door) + a gated-basis ρ* re-seed +
      # cost-DSV + calibration. Data-flip (no redeploy) after all, per the csustained/cpop precedent.
      recurrence_gate_enabled: 0.0,
      recurrence_gate_r_full: 1.0,
      recurrence_gate_new_floor: 1.0
    }.freeze

    K = Data.define(*ILLUSTRATIVE.keys)

    def self.load
      stored = CalibrationConstant.where(key: ILLUSTRATIVE.keys.map(&:to_s)).pluck(:key, :value).to_h
      values = ILLUSTRATIVE.each_with_object({}) do |(key, default), acc|
        acc[key] = (stored[key.to_s] || default).to_f
      end
      K.new(**values)
    end
  end
end
