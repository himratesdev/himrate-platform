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
      # from L0. v — CCV. cell — CellResolver::Baseline (rho_star/rho_lo/rho_hi). k — { tau_delta }.
      def self.call(raw:, b_hard_usernames:, v:, cell:, k:)
        humans = raw.reject { |c| b_hard_usernames.include?(c.username) }
        eihc = EihcWeigher.eihc(humans, tau_delta: k.tau_delta)
        SoftBound.new(
          eihc: eihc,
          rho_obs: v.positive? ? eihc / v.to_f : 0.0,
          f_soft: Deficit.call(v, eihc, cell.rho_star),
          f_soft_lo: Deficit.call(v, eihc, cell.rho_lo),   # lenient ρ_lo → smaller deficit → gates label
          f_soft_hi: Deficit.call(v, eihc, cell.rho_hi)
        )
      end
    end
  end
end
