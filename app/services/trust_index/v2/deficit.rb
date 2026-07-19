# frozen_string_literal: true

module TrustIndex
  module V2
    # max(0, V − EIHC/ρ) — the count of viewers unexplained by an honest chat/CCV baseline ρ. Shared
    # by L2 (F_soft, per-cell ρ*) and L3 (F_self, own ρ_self_lo). Pure. (SRS FR-003/FR-005, «F_soft».)
    module Deficit
      def self.call(v, eihc, rho)
        return 0.0 if rho.nil? || rho <= 0

        [ v - eihc / rho.to_f, 0.0 ].max
      end
    end
  end
end
