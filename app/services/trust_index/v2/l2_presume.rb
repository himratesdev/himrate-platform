# frozen_string_literal: true

module TrustIndex
  module V2
    # L2 — soft fraud bound F_soft = max(0, V − EIHC/ρ*) (SRS FR-003, Glossary «F_soft»/«EIHC»/«ρ*»).
    # The ONLY layer that sees silent view-bots: it presumes fraud from the gap between the effective
    # independent human chatters (EIHC, B_hard stripped) and the un-poisonable per-cell honest baseline
    # ρ*. F_soft (median ρ*) moves the ERV number; F_soft_lo (lenient ρ_lo — honest≈0 by construction)
    # gates the label; F_soft_hi (ρ_hi) is the interval upper bound.
    class L2Presume
      SoftBound = Data.define(:eihc, :rho_obs, :f_soft, :f_soft_lo, :f_soft_hi)

      # raw — original per-chatter objects (EihcWeigher features + username). b_hard_usernames — Set
      # from L0. v — instant CCV. cell — CellResolver::Baseline (rho_star/rho_lo/rho_hi). k — { tau_delta }.
      # windowed_usernames / v_w — TI v2.1 BUG-A co-windowed inputs (both NIL = dormant, exactly today).
      #   When present: EIHC is computed over the trailing-60min roster SUBSET (windowed_usernames ⊆ raw,
      #   after B_hard strip) and the ρ_obs/F_soft denominator is the windowed V_W (median CCV over the
      #   same 60min). This makes ρ_obs = EIHC_W/V_W a same-window chat-share (kills the cumulative-EIHC /
      #   instant-V duration-confound that lets a long stream's departed chatters whiten a late injection).
      def self.call(raw:, b_hard_usernames:, v:, cell:, k:, windowed_usernames: nil, v_w: nil)
        humans = raw.reject { |c| b_hard_usernames.include?(c.username) }
        humans = humans.select { |c| windowed_usernames.include?(c.username) } if windowed_usernames
        # G1 (young-ramp decay guard): the deficit denominator is min(V_W, V_inst), NOT V_W alone. A young
        # stream that spiked early then DECAYED has a windowed median V_W ABOVE its current instant online
        # (V_W > V_inst); since Deficit is monotone-increasing in V, V_W would manufacture a false deficit /
        # authenticity hit on an honestly-shrinking audience. A FALLING online cannot hide a fresh injection
        # (that's V_inst > V_W → min picks V_W, unchanged), so capping V at instant is safe for recall:
        # a sustained injection has V_W ≈ V_inst (min ≈ either, still fires); only the decay FP is removed.
        # VERDICT path: dormant (ti_v2_cowindowed_rho OFF → v_w nil → v, byte-identical). SHADOW path is
        # NOT dormant: accrue_windowed_shadow (ti_v2_cowindowed_shadow ON via ALL_FLAGS) computes with a
        # real v_w, so this changes the LIVE emitted ρ_obs for decaying streams (EIHC_W/V_W → EIHC_W/min).
        # That is INTENDED: the windowed corpus must reflect the same capped frame the engine will use at
        # verdict time post-flip, so the P2 re-seed calibrates ρ* on the right definition. Pre-G1 windowed
        # samples (few hours) re-base to the capped frame on deploy — the P2 re-seed uses post-G1 samples.
        v_eff = v_w ? [ v_w, v ].min : v
        eihc = EihcWeigher.eihc(humans, tau_delta: k.tau_delta)
        SoftBound.new(
          eihc: eihc,
          rho_obs: v_eff.positive? ? eihc / v_eff.to_f : 0.0,
          f_soft: Deficit.call(v_eff, eihc, cell.rho_star),
          f_soft_lo: Deficit.call(v_eff, eihc, cell.rho_lo),   # lenient ρ_lo → smaller deficit → gates label
          f_soft_hi: Deficit.call(v_eff, eihc, cell.rho_hi)
        )
      end
    end
  end
end
