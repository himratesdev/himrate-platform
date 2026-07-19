# frozen_string_literal: true

module TrustIndex
  module V2
    # L3 — take-the-worst fusion F̂ = max(F_hard, F_soft, F_self) under the recall-on-fraud loss
    # asymmetry (SRS FR-004/FR-005, Glossary «F̂»/«F_self»). F_soft already excludes B_hard from EIHC,
    # so max (NOT sum) is a total-fraud estimate that avoids double-counting. F_self is a gated 3rd arm
    # — fires ONLY on a clean sufficient self-history AND an inflation event (I=1) AND ¬raid; as a
    # max-arm it can only ADD recall (convert-from-honest inflation). F_self = max(0, V − EIHC/ρ_self_lo),
    # honest≈0 by construction.
    class L3Fuse
      FraudCount = Data.define(:f_hat, :f_hat_lo, :f_hat_hi, :f_self)

      # hard — L1 HardFloor. soft — L2 SoftBound. self_ctx — responds to: eligible (bool), v, eihc,
      #   rho_self_lo. (eligibility = clean-self-history ∧ I=1 ∧ ¬raid, assembled by the engine.)
      def self.call(hard:, soft:, self_ctx:)
        f_self = self_ctx.eligible ? Deficit.call(self_ctx.v, self_ctx.eihc, self_ctx.rho_self_lo) : 0.0
        FraudCount.new(
          f_hat: [ hard.f_hard, soft.f_soft, f_self ].max,
          f_hat_lo: [ hard.f_hard_lo, soft.f_soft_lo, f_self ].max,
          f_hat_hi: [ hard.f_hard_hi, soft.f_soft_hi, f_self ].max,
          f_self: f_self
        )
      end
    end
  end
end
