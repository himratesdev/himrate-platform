# frozen_string_literal: true

module TrustIndex
  module V2
    # L4 — emit ERV + interval + band + reason codes + plashka (SRS FR-006/007/008/009/010).
    # ERV = V − F̂ (subtracted count, clamped ≥0); authenticity A = 100·(1−F̂/V); â = F̂/V. The label
    # comes from the 6-row band table (BandClassifier) on N_frac/I/â/Q/tier — NOT an A-threshold.
    # The plashka (confirmed_anomaly) renders on C_hard (N_frac ≥ φ_yellow) ∨ C_self (I=1) ∨
    # C_inflation (TI v2.1 CCV-shape corroborator, only when the band is accusatory — row ≤ 2).
    class L4Emit
      EmitResult = Data.define(:erv, :erv_lo, :erv_hi, :authenticity, :a_hat, :n_frac,
                               :band, :reason_codes, :confirmed_anomaly, :cold_start_tier,
                               :confidence_marker, :c_hard, :c_self)

      # hard — L1 HardFloor (f_hard_lo → N_frac). soft — L2 SoftBound (f_soft_lo → band rows 1-2).
      # fraud — L3 FraudCount. ctx — v, n_chat_eff, q, i_event, raid_window, cold_start_tier,
      #   named_count, self_history_stable, chatter_quality_high, stream_count, unattributed_surge,
      #   thin_sample, ccv_chat_divergence, v_w (BUG-A windowed band frame), cell_calibrated,
      #   i_event_sustained, c_pop (C_pop population corroborator). k — thresholds
      #   (phi_yellow/phi_red/q_mid/q_hi + inflation_corrob_enabled/phi_inflation).
      # fraud_display (TI v2.1 two-EIHC split) — the fraud computed on an UNGATED EIHC (recurrence_gate
      # neutralized). erv/authenticity/â (the PUBLIC number) use it so an honest channel's first-time
      # chatters, downweighted for the ACCUSATION, never drop the displayed authenticity. The band +
      # corroborators keep the gated `fraud`/`soft`. Defaults to `fraud` → byte-identical when the gate is
      # dormant or a caller doesn't split.
      def self.call(hard:, soft:, fraud:, ctx:, k:, fraud_display: nil)
        new(hard, soft, fraud, ctx, k, fraud_display).call
      end

      def initialize(hard, soft, fraud, ctx, k, fraud_display = nil)
        @hard = hard
        @soft = soft
        @f = fraud
        @c = ctx
        @k = k
        @fd = fraud_display || fraud # DISPLAY fraud (ungated); == @f when dormant / not split
      end

      def call
        band = BandClassifier.call(drivers: band_drivers, k: @k)
        EmitResult.new(
          # DISPLAY (ungated) — the public ERV/authenticity number, protected from the recurrence_gate
          # downweight (@fd == @f when dormant → byte-identical).
          erv: clamp0(@c.v - @fd.f_hat), erv_lo: clamp0(@c.v - @fd.f_hat_hi), erv_hi: clamp0(@c.v - @fd.f_hat_lo),
          authenticity: authenticity, a_hat: a_hat, n_frac: n_frac, band: band,
          reason_codes: ReasonCodeBuilder.call(band: band, ctx: reason_ctx),
          confirmed_anomaly: c_hard || c_self || ((c_inflation || @c.c_pop || c_hard_abs) && band.row <= 2),
          cold_start_tier: @c.cold_start_tier,
          confidence_marker: confidence_marker, c_hard: c_hard, c_self: c_self
        )
      end

      private

      def ratio(x)
        @c.v.positive? ? x / @c.v.to_f : 0.0
      end

      # TI v2.1 BUG-A: the BAND-decision frame divides by V_W (the windowed deficit denominator) when
      # co-windowed, so the f_soft_lo / f_self / â ratios that GATE the band are judged against the SAME
      # V the deficit was computed on. Dividing a V_W-based deficit by INSTANT V would dilute the
      # accusatory ratio during a viewbot spike (V_inst≫V_W) → leaked fraud recall (the red-team seam).
      # Display surfaces (ERV, authenticity, Result.a_hat) keep instant V via ratio(). Dormant (v_w nil)
      # → v_band == @c.v → ratio_band == ratio → byte-identical band decisions.
      # G1 (young-ramp decay guard): min(V_W, V_inst) — the band ratios divide by the SAME capped V the
      # L2 deficit used (l2_presume), so a decaying young stream (V_W > V_inst) can't manufacture an
      # inflated accusatory ratio. Sustained injection has V_W ≈ V_inst → min ≈ either (recall preserved).
      def v_band
        @c.v_w ? [ @c.v_w, @c.v ].min : @c.v
      end

      def ratio_band(x)
        v_band.positive? ? x / v_band.to_f : 0.0
      end

      def clamp0(x)
        [ x, 0.0 ].max
      end

      # DISPLAY â = F̂/V on the UNGATED fraud (the public number). The BAND's â (green-gate + row6 sub)
      # uses the GATED @f via ratio_band(@f.f_hat) in band_drivers — accusation stays on the gated deficit.
      def a_hat
        ratio(@fd.f_hat)
      end

      def authenticity
        (100.0 * (1.0 - a_hat)).clamp(0.0, 100.0)
      end

      def n_frac
        @c.n_chat_eff.positive? ? @hard.f_hard_lo / @c.n_chat_eff.to_f : 0.0
      end

      def c_hard
        n_frac >= @k.phi_yellow
      end

      # FULL-CHAIN M3 c_hard hybrid — the INTEGER named-count trigger. The fraction path (c_hard) is
      # P5-diluted + fraction-gated, so a mid-roster 3-10 confirmed-bot cluster reads GREEN (anastaze 15.9%
      # R7 → n_frac 0.064). c_hard_abs fires on the COUNT of publicly-named (B_hard) members (not the P5
      # statistic) with a roster floor + a population-normalized share (never a naked absolute — roaming
      # spam bots visit hundreds of channels). Naming legality unchanged (only B_hard members named). B2
      # (red-team): YELLOW-ONLY — it feeds row2 + the plashka, NEVER independently_corroborated? (RED), so
      # a spam campaign parking 3 roamers + a coincidental deficit can't manufacture a public RED. DORMANT:
      # chard_abs_enabled=0.0 → false before any read → byte-identical (golden); 999 backstops un-fireable.
      # NOTE: this method is NOT itself cold-start-tier-gated — the full-tier gate lives in BandClassifier
      # row2 (accusable_tier? && c_hard_abs); confirmed_anomaly re-couples via `&& band.row <= 2` so a basic-
      # tier channel (which can't reach row2 off c_hard_abs) never shows the plashka. (CR nit.)
      def c_hard_abs
        return false unless @k.respond_to?(:chard_abs_enabled) && @k.chard_abs_enabled.to_f.positive?

        # M3.1: trigger on the DEDICATED named count (mc-filtered), NOT the full named_count — a roaming-spam
        # member (mc≥15) can't lift a big honest channel into accusation. named_count_dedicated ==
        # named_count at the dormant mc_max default (999) → byte-identical. Falls back to named_count when the
        # ctx double predates the field (isolated unit tests) → old behavior preserved.
        dedicated = @c.respond_to?(:named_count_dedicated) && !@c.named_count_dedicated.nil? ? @c.named_count_dedicated : @c.named_count
        dedicated.to_i >= @k.chard_abs_count.to_f &&
          @c.n_chat_eff.to_i >= @k.chard_abs_roster_min.to_f &&
          (@c.n_chat_eff.positive? ? dedicated.to_f / @c.n_chat_eff : 0.0) >= @k.chard_abs_share.to_f
      end

      def c_self
        @c.i_event
      end

      # TI v2.1 (BUG-A/B pivot): the INDEPENDENT second corroborator that breaks the C_hard
      # monoculture. Fires on a CCV-shape inflation signature (CcvChatCorrelation: CCV↑ ∧ chat-flat =
      # silent-viewbot injection) — orthogonal to both the named-bot axis (C_hard) and the deficit
      # magnitude (F_soft). Excludes organic raids (raid_window). DORMANT by default:
      # inflation_corrob_enabled=0.0 → always false → corroborated? == today. The kill-switch is the
      # enabled flag (a data update flips it post-BUG-A + calibration, no redeploy). The respond_to?
      # guard keeps isolated-K unit doubles working before they add the two constants.
      def c_inflation
        @k.respond_to?(:inflation_corrob_enabled) &&
          @k.inflation_corrob_enabled.to_f.positive? &&
          @c.ccv_chat_divergence.to_f >= @k.phi_inflation.to_f &&
          !@c.raid_window
      end

      def confidence_marker
        @c.cold_start_tier == "basic" || @c.thin_sample ? "provisional" : "reliable"
      end

      def band_drivers
        BandClassifier::Drivers.new(
          n_frac: n_frac, f_self_ratio: ratio_band(@f.f_self), f_soft_lo_ratio: ratio_band(@soft.f_soft_lo),
          a_hat: ratio_band(@f.f_hat), q: @c.q, i_event: @c.i_event, c_hard: c_hard, c_self: c_self,
          c_inflation: c_inflation, raid_window: @c.raid_window, cold_start_tier: @c.cold_start_tier,
          cell_calibrated: @c.cell_calibrated, i_event_sustained: @c.i_event_sustained, c_pop: @c.c_pop,
          c_hard_abs: c_hard_abs
        )
      end

      def reason_ctx
        ReasonCodeBuilder::Ctx.new(
          # M3: the integer-count path names the SAME B_hard members → emit HARD_NAMED_FRACTION for it too
          # (the code + {n, pct} params are valid for both fraction and count triggers; named_pct is the true
          # sub-φ_yellow fraction). The c_inflation/c_pop "!c_hard" dedup then correctly defers to named evidence.
          c_hard: c_hard || c_hard_abs, c_self: c_self, c_inflation: c_inflation, i_event_sustained: @c.i_event_sustained,
          c_pop: @c.c_pop,
          named_count: @c.named_count, named_pct: (n_frac * 100.0).round(1),
          self_history_stable: @c.self_history_stable, chatter_quality_high: @c.chatter_quality_high,
          cold_start_tier: @c.cold_start_tier, stream_count: @c.stream_count,
          raid_window_suppressed_i: @c.raid_window, unattributed_surge: @c.unattributed_surge,
          thin_sample: @c.thin_sample
        )
      end
    end
  end
end
