# frozen_string_literal: true

require "set"

module TrustIndex
  module V2
    # V2 engine orchestrator (SRS §2, ADR DEC-1). Runs L0→L4 STRICTLY sequentially — each layer only
    # ADDs fraud and the single reconcile is L3's max, so the anti-convex-average guarantee is
    # structural (no weighted-average node). Reads a pre-assembled Context (ContextBuilder) → pure
    # orchestration, testable without CH/PG. Emits V2::Engine::Result; #to_headline_payload adapts it
    # to the engine-agnostic publish contract (DEC-7) so SignalComputeWorker never reads fields directly.
    class Engine
      # The engine's INPUT contract (assembled by TrustIndex::ContextBuilder#build_v2, ADR DEC-6 — no
      # new context_builder.rb; we extend the existing one). Nested under Engine (not module V2) so
      # Zeitwerk resolves it from engine.rb — the file's expected constant. Every field the L0→L4 layers
      # read is named here so the contract is one grep; unit tests build these directly (no CH/PG).
      # A "silent" source contributes L_k=0 (FR-001 п.2) — the DESIGNED neutral, not a stub: ContextBuilder
      # wires the two SRS-illustrative-LLR sources (temporal_recurrence, known_bot_hit) and leaves the
      # GATE-0-calibration-pending ones neutral until their calibration lands (additive, not a rewrite).
      ChatterSignals = Data.define(
        :username, :temporal_recurrence, :known_bot_hit, :per_user_bot_score,
        :account_profile_llr, :anti_bot_llr, :cluster_delta_k, :cluster_size, :age_gate, :recurrence_gate
      )

      Context = Data.define(
        :v, :raw_chatters, :cell, :rho_self_lo, :clean_self_history, :self_history_stable,
        # i_event = the FINAL self-history tripwire (C_self / F_self). The engine DERIVES it (derive_i_event,
        # after L2) from the L2-internal deficit [1] + i_event_external + raid + enabled-gate; the builder
        # passes i_event:false (a literal — the engine overrides). i_event_external = the pre-ANDed 5 external
        # conjuncts [2/4/5/6] the builder computes (bounded PG/context reads), false when i_event_enabled=0.0
        # (dormant → no fetches). Conjunct [1] rho_dropped needs L2's soft.eihc so it can't live in the builder.
        :i_event, :i_event_external, :raid_window, :n_chat_eff, :q, :cold_start_tier, :chatter_quality_high,
        :stream_count, :unattributed_surge, :thin_sample, :reputation, :cps,
        # TI v2.1: CcvChatCorrelation value (0-1, CCV↑ ∧ chat-flat = silent-injection signature).
        # Feeds L4's C_inflation corroborator. 0.0 = no signature / dormant. Names nobody (CCV-shape).
        :ccv_chat_divergence,
        # TI v2.1 BUG-A (co-windowed ρ_obs): the trailing-60min L2 inputs. Both NIL when the
        # ti_v2_cowindowed_rho flag is OFF → the engine reproduces today's cumulative-roster / instant-V
        # behavior byte-for-byte (dormant). l2_roster_usernames = the windowed chatter Set (a subset of
        # raw_chatters used for the EIHC numerator); v_w = median CCV over the same 60min (the deficit
        # denominator). Cumulative raw_chatters still drives L0 B_hard + cross-channel; instant :v still
        # drives ERV/authenticity display.
        :l2_roster_usernames, :v_w,
        # G5 (lurker-collapse guard): the channel's own honest CCV baseline (median of clean,
        # convention-scoped own-CCV history). nil when history is too thin. L2 uses it to distinguish an
        # elevated-online injection (keep deficit) from stable-online honest quieting (floor deficit).
        :own_ccv_baseline,
        # TI v2.1 C_self^SP (Sustained-Plateau self-corroborator): sustained_count = the CURRENT stream's
        # leading run of consecutive windowed elevated-deficit TIH windows (builder-reconstructed from
        # append-only history; 0 + no read when csustained_enabled≤0). ccv_cov = CoV of the trailing-30min
        # CCV series (the flat-and-high plateau shape [P3]). Both inert unless csustained_enabled>0.
        :sustained_count, :ccv_cov,
        # TI v2.1 C_pop (population-anchored, silent-always-botter fix): the CHANNEL's cross-stream density
        # of deficit windows (0 + no read when cpop_enabled≤0). Fed to the C_pop persistence gate.
        :pop_deficit_density
      )

      SelfCtx = Data.define(:eligible, :v, :eihc, :rho_self_lo)
      EmitCtx = Data.define(:v, :n_chat_eff, :q, :i_event, :raid_window, :cold_start_tier,
                            :named_count, :self_history_stable, :chatter_quality_high,
                            :stream_count, :unattributed_surge, :thin_sample, :ccv_chat_divergence,
                            # TI v2.1 BUG-A: windowed V_W (nil dormant) — L4 divides band-driver ratios
                            # by V_W (deficit frame) while ERV/authenticity keep instant :v (display).
                            :v_w,
                            # moat-audit: whether the per-cell ρ* is a real GATE-0 cell — the f_soft
                            # accusatory branch never fires off an uncalibrated/DEFAULT cell.
                            :cell_calibrated,
                            # TI v2.1 C_self^SP: i_event was set by the SUSTAINED-plateau arm and NOT the
                            # legacy 6-AND step → a single deficit-family signal → capped at YELLOW (row2);
                            # public RED requires an independent corroborator (C_hard/C_inflation).
                            :i_event_sustained,
                            # TI v2.1 C_pop: the population-anchored corroborator fired (persistent sub-P1
                            # chat-share vs a calibrated cell, online inflated) — lets F_soft accuse a silent
                            # always-botter. Capped at YELLOW in the band (population-alone never public RED).
                            :c_pop)

      Result = Data.define(:erv, :erv_lo, :erv_hi, :authenticity, :a_hat, :n_frac, :band,
                           :reason_codes, :confirmed_anomaly, :cold_start_tier, :confidence_marker,
                           :c_hard, :c_self, :axes, :eihc, :rho_obs, :f_hat, :f_hat_lo, :f_hat_hi,
                           :f_hard, :f_hard_lo, :f_self,
                           # PR3a (T1-074) — additive observability breakdown (no logic change): L2 soft
                           # deficit + interval, authenticity interval, Q. Persisted for /erv
                           # erv_breakdown{f_hard,f_soft,f_hat} (Surface 2) + richer shadow diff.
                           :f_soft, :f_soft_lo, :f_soft_hi, :authenticity_lo, :authenticity_hi, :q_score,
                           # TI v2.1 P0.5 — provenance stamp for rho_obs: "cumulative" (instant-V, flag OFF)
                           # or "windowed" (V_W, flag ON). Persisted so the self-baseline + ρ* miner segregate
                           # conventions across the 90-day horizon (nil when rho_obs is nil, e.g. V≤0).
                           :rho_convention,
                           :b_hard, :engine_version) do
        # DEC-7 adapter — the engine maps its own fields to the publish payload; SCW calls this.
        def to_headline_payload
          { erv: erv, erv_interval: { lo: erv_lo, hi: erv_hi }, authenticity: authenticity,
            axes: axes.to_h, band: band.to_h, reason_codes: reason_codes.map(&:to_h),
            confirmed_anomaly: { shown: confirmed_anomaly }, cold_start_tier: cold_start_tier,
            confidence_marker: confidence_marker, engine_version: engine_version }
        end
      end

      # All-null Result skeleton for the EC-15 (V≤0) short-circuit — no headline number, GREY band.
      EMPTY_RESULT = {
        erv: nil, erv_lo: nil, erv_hi: nil, authenticity: nil, a_hat: nil, n_frac: nil, band: nil,
        reason_codes: [], confirmed_anomaly: false, cold_start_tier: nil, confidence_marker: "provisional",
        c_hard: false, c_self: false, axes: nil, eihc: nil, rho_obs: nil, f_hat: nil, f_hat_lo: nil,
        f_hat_hi: nil, f_hard: nil, f_hard_lo: nil, f_self: nil,
        f_soft: nil, f_soft_lo: nil, f_soft_hi: nil, authenticity_lo: nil, authenticity_hi: nil, q_score: nil,
        rho_convention: nil, # V≤0 short-circuit → rho_obs nil → no convention applies
        b_hard: [], engine_version: "v2"
      }.freeze

      def self.compute(context:, k:)
        new(context, k).compute
      end

      def initialize(context, k)
        @ctx = context
        @k = k
        @i_event_sustained = false # set by derive_i_event; read by emit_ctx (single compute() pass)
      end

      def compute
        return offline_result if @ctx.v.nil? || @ctx.v <= 0 # EC-15: V≤0 / null CCV → GREY, never a headline number

        post = L0Identity.call(@ctx.raw_chatters, k: @k)
        hard = L1Subtract.call(post)
        soft = L2Presume.call(raw: @ctx.raw_chatters, b_hard_usernames: names(post),
                              v: @ctx.v, cell: @ctx.cell, k: @k,
                              windowed_usernames: @ctx.l2_roster_usernames, v_w: @ctx.v_w,
                              own_ccv_baseline: @ctx.own_ccv_baseline,
                              # respond_to? keeps isolated-K unit doubles green (mirrors derive_i_event)
                              lurker_collapse_ratio: (@k.lurker_collapse_ratio if @k.respond_to?(:lurker_collapse_ratio)))
        i_evt = derive_i_event(soft) # i_event EPIC: derived AFTER L2 (needs soft.eihc for [1] rho_dropped)
        fraud = L3Fuse.call(hard: hard, soft: soft, self_ctx: self_ctx(soft, i_evt), sum_disjoint: windowed?)
        # TI v2.1 two-EIHC split: the DISPLAY fraud (ungated EIHC) drives the public ERV/authenticity number
        # so recurrence_gate's honest-first-timer downweight never drops it; the gated `fraud`/`soft` drive
        # the accusation (band + corroborators + persisted ledger deficit). Dormant → fraud_disp == fraud.
        fraud_disp = display_fraud(post, hard, i_evt, fraud)
        emit = L4Emit.call(hard: hard, soft: soft, fraud: fraud, fraud_display: fraud_disp,
                           ctx: emit_ctx(post, i_evt, soft), k: @k)
        Result.new(**emit.to_h, **extras(post, hard, soft, fraud, fraud_disp, emit))
      end

      private

      # EC-15 / TC-017: V≤0 or null CCV → ERV & axes null, GREY band, WIDE_INTERVAL_THIN_SAMPLE reason.
      # Never a headline number, never GREEN/accusatory (the division A=100·(1−F̂/V) is undefined at V=0).
      def offline_result
        Result.new(**EMPTY_RESULT, cold_start_tier: @ctx.cold_start_tier,
          band: BandClassifier::Band.new(row: 5, color: "grey", label_key: "band.grey_insufficient", sub: nil),
          reason_codes: [ ReasonCodeBuilder::Code.new(code: "WIDE_INTERVAL_THIN_SAMPLE", params: {}) ],
          axes: AxesBuilder.call(authenticity: nil, reputation: @ctx.reputation, rho_obs: nil, cps: @ctx.cps))
      end

      def names(post)
        post.b_hard.map(&:username).to_set
      end

      # TI v2.1 BUG-A: co-windowed mode is active iff ContextBuilder populated v_w (flag ON). Drives
      # the L2 deficit frame, the L3 disjoint-sum, and the L4 band-driver V frame. Nil ⇒ dormant.
      # Pre-FLIP blockers (tracked in _tasks/T1-074/BUG-A-SEMANTICS-SYNTHESIS): rho_convention TIH stamp,
      # lurker-collapse guard (honest quiet-chat → windowed EIHC→0), sparse-cell variance gate, ρ* re-seed.
      def windowed?
        !@ctx.v_w.nil?
      end

      # i_event EPIC (T1-074, C_self / G-monoculture fix): compose the FINAL i_event AFTER L2 (needs
      # soft.eihc for conjunct [1] rho_dropped, which only exists inside the engine) as the disjunction of
      # TWO independently-gated self-history arms — the abrupt-STEP 6-AND (legacy_i_event) OR the HELD-
      # plateau C_self^SP (sustained_plateau?). Both dormant by default via their OWN kill-switches, so
      # i_event stays byte-identical to today at defaults. @i_event_sustained records whether the fire is
      # sustained-ONLY (no concurrent step) — the band caps such a single deficit-family signal at YELLOW.
      def derive_i_event(soft)
        legacy    = legacy_i_event(soft)     # the abrupt-STEP 6-AND arm (own i_event_enabled gate)
        sustained = sustained_plateau?(soft) # the HELD-plateau C_self^SP arm (own csustained_enabled gate)
        # A sustained-ONLY fire (no concurrent step) is a single deficit-family signal → it caps at YELLOW
        # downstream; the legacy step, when present, IS the independent second signal → RED path unchanged.
        @i_event_sustained = sustained && !legacy
        legacy || sustained
      end

      # The abrupt-STEP arm (convert-from-honest inflation). DORMANT: the i_event_enabled=0.0 kill-switch
      # short-circuits to false BEFORE reading any ie_* input or the external partial → byte-identical to
      # the hardcoded-false behavior today (proof: golden spec). respond_to? keeps isolated-K unit doubles
      # working; the golden/flip specs assert the field is present so a fumbled K-double can't merge a
      # broken wire green (red-team SHOULD-FIX #4). Delegates the 6-way AND to InflationEvent.call so the
      # conjunction lives in ONE place. i_event_external is the builder's pre-ANDed [2]∧[4]∧[5]∧[6]; [1] is
      # engine-internal; [3]/tier read straight from Context.
      def legacy_i_event(soft)
        return false unless @k.respond_to?(:i_event_enabled) && @k.i_event_enabled.to_f.positive?

        InflationEvent.call(InflationEvent::Conditions.new(
          rho_dropped_vs_baseline: rho_dropped?(soft),            # [1] ENGINE-INTERNAL (soft.eihc, self_v frame)
          v_above_own_trend: @ctx.i_event_external,               # [2]∧[4]∧[5]∧[6] pre-ANDed by builder
          raid_window: @ctx.raid_window,                         # [3] (negated inside InflationEvent)
          chat_arrival_below_floor: true,                        # folded into i_event_external
          no_follower_sub_bump: true,                            # folded into i_event_external
          variance_below_floor_or_plateau: true,                 # folded into i_event_external
          unattributed_surge: @ctx.unattributed_surge,
          cold_start_tier: @ctx.cold_start_tier
        )).i_event
      end

      # TI v2.1 C_self^SP (Sustained-Plateau self-corroborator) — the DURABLE self-history arm that catches a
      # HELD silent-viewbot plateau where the legacy 6-AND step detector is dead ([2] v-surge z→0 once the
      # injection is held, [5] follower-conv confounded by co-arriving real humans). Every predicate is a
      # LEVEL/shape comparison that PERSISTS across the plateau. DORMANT: csustained_enabled=0.0 short-
      # circuits at the first guard, BEFORE reading sustained_count / ccv_cov → i_event byte-identical to
      # the legacy arm alone (golden spec). FP-safety is structural & multi-guard (each honest case is blocked
      # by a DIFFERENT live predicate): honest quiet-chat → [P2] online_elevated false (same G5 discriminator);
      # honest good-day → [P1] rho_dropped false (proportional chat); honest viral onset → [P3] plateau_shape
      # false (rising = high CoV) AND the run clears before N. Thin-history → [P6] full-tier. Windowed frame
      # (self_v = min(V_W,V_inst)) carries [P1]/[P2] so a decaying online can't manufacture a false deficit.
      def sustained_plateau?(soft)
        return false unless @k.respond_to?(:csustained_enabled) && @k.csustained_enabled.to_f.positive?
        return false if @ctx.rho_self_lo.nil? || !@ctx.self_history_stable # no honest windowed baseline to fall below
        return false unless @ctx.cold_start_tier == "full"                 # [P6] G4 — never accuse a thin-history channel
        return false if @ctx.raid_window || @ctx.unattributed_surge        # [P4]/[P5] provenance exclusions
        return false unless rho_dropped?(soft)                             # [P1] persistent windowed chat-share deficit (reuse)
        return false unless online_elevated?                              # [P2] online held above own honest baseline (G5-inverse)
        return false unless plateau_shape?                                # [P3] flat-and-high CCV (a rising viral surge → high CoV → excluded)

        (@ctx.sustained_count.to_i + 1) >= @k.csustained_n_windows.to_f   # durability: this window + the persisted leading run ≥ N
      end

      # [P2] G5-INVERSE: the online is HELD above the channel's own honest CCV baseline (an injection to
      # presume), on the SAME G1-capped frame [P1]/F_self use (self_v). An honest quiet-chat stream (stable,
      # not elevated online) is excluded here by the exact discriminator G5 floors the deficit on.
      def online_elevated?
        b = @ctx.own_ccv_baseline
        b.to_f.positive? && self_v > b.to_f * (1 + @k.csustained_elevated_margin.to_f)
      end

      # [P3] plateau_shape: the trailing-30min CCV CoV is compressed (a viewbot service holds a target count
      # → the injected component is near-constant → total CoV collapses). Separates a HELD botted plateau
      # from a RISING honest surge (high CoV while ramping). ccv_cov nil (<5 pts) → not flat → no fire.
      def plateau_shape?
        cov = @ctx.ccv_cov
        !cov.nil? && cov < @k.csustained_cov_ceiling.to_f
      end

      # [1] rho_dropped_vs_baseline ⟺ EIHC/V < rho_self_lo ⟺ Deficit(V, EIHC, rho_self_lo) > 0 — the EXACT
      # F_self quantity on the EXACT frame self_ctx uses (self_v + soft.eihc + rho_self_lo). No baseline
      # (nil / not-yet-stable self-history) → false: never presume an inflation event without an honest
      # own-history floor to fall below (matches the clean_self_history/self_history_stable gate). FP-safety
      # of this conjunct depends on the WINDOWED frame (honest late-quieting drops V+EIHC together on the
      # windowed roster) — the flip is sequenced AFTER the BUG-A windowing flip (PRE-FLIP-BLOCKER-MAP).
      def rho_dropped?(soft)
        return false if @ctx.rho_self_lo.nil? || !@ctx.self_history_stable

        Deficit.call(self_v, soft.eihc, @ctx.rho_self_lo).positive?
      end

      # Shared deficit frame: G1 min(V_W, V_inst) when co-windowed (a falling online can't hide an
      # injection), else instant V (dormant, unchanged). self_ctx (F_self) and rho_dropped? [1] MUST
      # divide by the SAME V or [1] would gate F_self on a different deficit than F_self itself computes.
      def self_v
        @ctx.v_w ? [ @ctx.v_w, @ctx.v ].min : @ctx.v
      end

      def self_ctx(soft, i_evt)
        eligible = @ctx.clean_self_history && i_evt && !@ctx.raid_window
        # F_self shares the deficit frame: G1 min(V_W, V_inst) when co-windowed (same young-ramp decay
        # guard as L2/L4 — a falling online can't hide an injection), else instant V (dormant, unchanged).
        # N-2: in decay this suppresses the F_self convert-from-honest escalation to the smaller current
        # online — intended: a streamer whose bots LEFT mid-stream shouldn't be flagged via F_self for the
        # earlier, now-departed inflation (ERV is point-in-time; a shrinking online hosts no live injection).
        SelfCtx.new(eligible: eligible, v: self_v, eihc: soft.eihc, rho_self_lo: @ctx.rho_self_lo)
      end

      # TI v2.1 two-EIHC split — the DISPLAY fraud on an UNGATED EIHC (recurrence_gate neutralized to 1.0),
      # feeding erv/authenticity/â (the public number) so an honest channel's first-time chatters (floored
      # for the accusation) never drop the displayed authenticity — the account_profile-leak-through-display
      # fix. DORMANT: when no chatter is downweighted (every recurrence_gate == 1.0 — the flag-off state),
      # the ungated pipeline IS the gated one → returns the gated `fraud` unchanged (ZERO recompute) →
      # byte-identical. Live: one cheap second L2→L3 pass over the SAME roster/b_hard (pure Ruby, no CH/PG).
      def display_fraud(post, hard, i_evt, fraud)
        return fraud unless recurrence_downweighted?

        soft_disp = L2Presume.call(raw: ungated_chatters, b_hard_usernames: names(post),
                                   v: @ctx.v, cell: @ctx.cell, k: @k,
                                   windowed_usernames: @ctx.l2_roster_usernames, v_w: @ctx.v_w,
                                   own_ccv_baseline: @ctx.own_ccv_baseline,
                                   lurker_collapse_ratio: (@k.lurker_collapse_ratio if @k.respond_to?(:lurker_collapse_ratio)))
        L3Fuse.call(hard: hard, soft: soft_disp, self_ctx: self_ctx(soft_disp, i_evt), sum_disjoint: windowed?)
      end

      # The split is live iff some chatter carries a recurrence_gate < 1.0 (the gate flipped + this roster
      # has a first-time/partial chatter). All 1.0 (dormant / no downweight) → skip the second pass.
      def recurrence_downweighted?
        @ctx.raw_chatters.any? { |c| c.respond_to?(:recurrence_gate) && c.recurrence_gate.to_f < 1.0 }
      end

      # The roster with recurrence_gate neutralized to 1.0 (age_gate / cluster untouched) — the display basis.
      def ungated_chatters
        @ctx.raw_chatters.map { |c| c.respond_to?(:with) ? c.with(recurrence_gate: 1.0) : c }
      end

      def emit_ctx(post, i_evt, soft)
        EmitCtx.new(v: @ctx.v, n_chat_eff: @ctx.n_chat_eff, q: @ctx.q, i_event: i_evt,
                    raid_window: @ctx.raid_window, cold_start_tier: @ctx.cold_start_tier,
                    named_count: post.b_hard.size, self_history_stable: @ctx.self_history_stable,
                    chatter_quality_high: @ctx.chatter_quality_high, stream_count: @ctx.stream_count,
                    unattributed_surge: @ctx.unattributed_surge, thin_sample: @ctx.thin_sample,
                    ccv_chat_divergence: @ctx.ccv_chat_divergence, v_w: @ctx.v_w,
                    # respond_to? keeps isolated cell-doubles working (mirrors the i_event/lurker guards);
                    # nil/absent → treated as uncalibrated → f_soft branch cannot publicly accuse.
                    cell_calibrated: (@ctx.cell.calibrated if @ctx.cell.respond_to?(:calibrated)),
                    # TI v2.1 C_self^SP: set by derive_i_event (called just above in compute) — a sustained-
                    # only self-history inflation caps the band at YELLOW unless independently corroborated.
                    i_event_sustained: @i_event_sustained,
                    # TI v2.1 C_pop: population-anchored corroborator (needs soft.rho_obs, post-L2).
                    c_pop: pop_corroborated?(soft))
      end

      # TI v2.1 C_pop (population-anchored F_soft accusation — the SILENT ALWAYS-BOTTER fix). The three
      # existing corroborators are CHANNEL-referential (C_hard = named bots in ITS chat; C_self = an
      # inflation step in ITS history; C_inflation = a CCV-step in ITS stream) → a silent always-botter
      # defeats all three (no names, no honest history — the de-poison leaves its self-baseline EMPTY, so
      # C_self/[P1]/[P2] all gate off — no step). It reads AMBER 6b forever. C_pop uses the PEER POPULATION
      # as the independent reference: the calibrated cell ρ* is the un-poisonable honest chat-share of the
      # channel's cell; a persistent chat-share below the cell's P1 tail, with online INFLATED vs the
      # cell-typical, IS anomalous vs peers (population + time axes are orthogonal to the channel's own data
      # — not deficit-corroborating-deficit; a farm can't launder ρ*). DORMANT: cpop_enabled=0.0 short-
      # circuits before any read → c_pop=false → corroborated? byte-identical. Also inert until the re-seed
      # writes rho_p1/ccv_typical (nil → false) — a third dormancy gate. Capped at YELLOW in the band.
      def pop_corroborated?(soft)
        return false unless @k.respond_to?(:cpop_enabled) && @k.cpop_enabled.to_f.positive?
        return false unless @ctx.cell.respond_to?(:calibrated) && @ctx.cell.calibrated  # never off DEFAULT ρ*
        return false unless @ctx.cold_start_tier == "full"                              # never a thin-history channel
        return false if @ctx.raid_window || @ctx.unattributed_surge                     # provenance exclusions
        rho_p1 = (@ctx.cell.rho_p1 if @ctx.cell.respond_to?(:rho_p1))
        return false if rho_p1.nil? || soft.rho_obs.nil?
        return false unless soft.rho_obs < rho_p1.to_f          # [4] TAIL cut: below 99% of honest peers (not P10)
        return false unless population_elevated?                # [5] online INFLATED vs cell-typical (the discriminator)

        @ctx.pop_deficit_density.to_f >= @k.cpop_density_frac.to_f  # [6] PERSISTENT across the channel's recent windows
      end

      # [5] population_elevated? — the discriminator that separates a silent botter (online INFLATED) from an
      # honest low-chat channel (online NORMAL-for-cell). A pure chat-deficit is byte-identical between a
      # botter and an honest channel mis-celled to a too-high ρ* — the online-elevation axis (vs the cell's
      # typical CCV) is orthogonal to the chat-share axis and breaks that tie. ccv_typical nil → inert.
      def population_elevated?
        t = (@ctx.cell.ccv_typical if @ctx.cell.respond_to?(:ccv_typical))
        !t.nil? && t.to_f.positive? && @ctx.v.to_f > t.to_f * (1 + @k.cpop_elevated_margin.to_f)
      end

      def extras(post, hard, soft, fraud, fraud_disp, emit)
        v = @ctx.v.to_f
        # DISPLAY basis (fraud_disp, ungated) — the headline number: f_hat/interval + authenticity interval,
        # paired with the display erv/authenticity from L4. GATED basis (soft/fraud) — the accusation
        # observability persisted to TIH + read back by the ledgers: eihc/rho_obs (→ρ* miner + self-history),
        # f_soft/f_soft_lo/f_soft_hi (→ C_self^SP sustained_count + C_pop pop_deficit_density), f_self.
        # Dormant → fraud_disp == fraud → both bases identical → byte-identical.
        { axes: AxesBuilder.call(authenticity: emit.authenticity, reputation: @ctx.reputation,
                                 rho_obs: soft.rho_obs, cps: @ctx.cps),
          eihc: soft.eihc, rho_obs: soft.rho_obs, f_hat: fraud_disp.f_hat, f_hat_lo: fraud_disp.f_hat_lo,
          f_hat_hi: fraud_disp.f_hat_hi, f_hard: hard.f_hard, f_hard_lo: hard.f_hard_lo,
          f_self: fraud.f_self,
          f_soft: soft.f_soft, f_soft_lo: soft.f_soft_lo, f_soft_hi: soft.f_soft_hi,
          # authenticity interval mirrors the DISPLAY ERV interval: MORE fraud (f_hat_hi) → LOWER authenticity.
          authenticity_lo: authenticity_pct(fraud_disp.f_hat_hi, v), authenticity_hi: authenticity_pct(fraud_disp.f_hat_lo, v),
          q_score: @ctx.q,
          # P0.5: stamp which ρ_obs convention this row used (windowed? = flag-ON co-windowed frame).
          rho_convention: (windowed? ? "windowed" : "cumulative"),
          b_hard: post.b_hard, engine_version: "v2" }
      end

      # A = 100·(1 − F̂/V) for an interval bound; nil at V≤0 (extras only runs when V>0, but be safe).
      def authenticity_pct(f, v)
        return nil unless v.positive?

        (100.0 * (1.0 - f / v)).clamp(0.0, 100.0)
      end
    end
  end
end
