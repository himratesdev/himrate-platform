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
      #   thin_sample. k — thresholds (phi_yellow/phi_red/q_mid/q_hi).
      def self.call(hard:, soft:, fraud:, ctx:, k:)
        new(hard, soft, fraud, ctx, k).call
      end

      def initialize(hard, soft, fraud, ctx, k)
        @hard = hard
        @soft = soft
        @f = fraud
        @c = ctx
        @k = k
      end

      def call
        band = BandClassifier.call(drivers: band_drivers, k: @k)
        EmitResult.new(
          erv: clamp0(@c.v - @f.f_hat), erv_lo: clamp0(@c.v - @f.f_hat_hi), erv_hi: clamp0(@c.v - @f.f_hat_lo),
          authenticity: authenticity, a_hat: a_hat, n_frac: n_frac, band: band,
          reason_codes: ReasonCodeBuilder.call(band: band, ctx: reason_ctx),
          confirmed_anomaly: c_hard || c_self || (c_inflation && band.row <= 2),
          cold_start_tier: @c.cold_start_tier,
          confidence_marker: confidence_marker, c_hard: c_hard, c_self: c_self
        )
      end

      private

      def ratio(x)
        @c.v.positive? ? x / @c.v.to_f : 0.0
      end

      def clamp0(x)
        [ x, 0.0 ].max
      end

      def a_hat
        ratio(@f.f_hat)
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
          n_frac: n_frac, f_self_ratio: ratio(@f.f_self), f_soft_lo_ratio: ratio(@soft.f_soft_lo),
          a_hat: a_hat, q: @c.q, i_event: @c.i_event, c_hard: c_hard, c_self: c_self,
          c_inflation: c_inflation, raid_window: @c.raid_window, cold_start_tier: @c.cold_start_tier
        )
      end

      def reason_ctx
        ReasonCodeBuilder::Ctx.new(
          c_hard: c_hard, c_self: c_self, c_inflation: c_inflation,
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
