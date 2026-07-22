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
      def self.call(hard:, soft:, self_ctx:, sum_disjoint: false)
        f_self = self_ctx.eligible ? Deficit.call(self_ctx.v, self_ctx.eihc, self_ctx.rho_self_lo) : 0.0
        FraudCount.new(
          f_hat: fuse(hard.f_hard, soft.f_soft, f_self, sum_disjoint),
          f_hat_lo: fuse(hard.f_hard_lo, soft.f_soft_lo, f_self, sum_disjoint),
          f_hat_hi: fuse(hard.f_hard_hi, soft.f_soft_hi, f_self, sum_disjoint),
          f_self: f_self
        )
      end

      # TI v2.1 BUG-A (red-team fix): F_hard (named chatting bots ∈ B_hard) and F_soft (silent viewbots,
      # from V−EIHC/ρ* where EIHC already EXCLUDES B_hard) count DISJOINT populations → they ADD, not
      # max. F_self (own-history inflation) OVERLAPS both → max against the additive hard+soft. The old
      # max(f_hard,f_soft,f_self) systematically UNDER-counted disjoint fraud (max(40,30)=40 vs the true
      # ~70). Gated behind sum_disjoint (the co-windowed flag) so this ERV-magnitude change ships WITH
      # the windowing flip, not before — keeping Phase-0 dormant byte-identical. Over-count vs V is
      # absorbed downstream by L4's clamp0(V−F̂) + the [0,100] authenticity clamp (no explicit cap needed).
      def self.fuse(f_hard, f_soft, f_self, sum_disjoint)
        sum_disjoint ? [ f_hard + f_soft, f_self ].max : [ f_hard, f_soft, f_self ].max
      end
    end
  end
end
