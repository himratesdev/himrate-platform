# frozen_string_literal: true

module TrustIndex
  module V2
    # L1 — hard fraud floor F_hard = Σ_{u∈B_hard} p_u with a dispute-safe P5 lower bound (SRS FR-002,
    # Glossary «F_hard»). Named chatting bots are physically in V → subtracted directly (no 1/α
    # multiplier); silent-sibling extrapolation is L2's job (soft), never inflating this floor.
    # F_hard_lo = P5 (the dispute-safe number we stand behind), F_hard_hi = P95.
    class L1Subtract
      HardFloor = Data.define(:f_hard, :f_hard_lo, :f_hard_hi)

      # posterior_set — L0Identity::PosteriorSet.
      def self.call(posterior_set)
        pb = PoissonBinomial.call(posterior_set.b_hard.map(&:p_u))
        HardFloor.new(f_hard: pb.mean, f_hard_lo: pb.p5, f_hard_hi: pb.p95)
      end
    end
  end
end
