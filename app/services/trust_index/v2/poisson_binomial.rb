# frozen_string_literal: true

module TrustIndex
  module V2
    # Poisson-binomial interval for Σ Bernoulli(p_u) — the count of named hard-bots (SRS FR-002).
    # F_hard = Σ p_u (mean); dispute-safe F_hard_lo = P5, F_hard_hi = P95 via a normal approximation
    # (mean = Σp, variance = Σp(1−p); CLT/Le Cam — adequate for |B_hard| ≳ 10, degrades to the mean on
    # tiny sets). Pure function, no I/O — unit-testable in isolation (ADR DEC-1 anti-convex guarantee).
    class PoissonBinomial
      Z_P05 = 1.6448536269514722 # one-sided 5th/95th percentile of N(0,1)

      Result = Data.define(:mean, :p5, :p95)

      # probs — Array<Float in [0,1]>: the per-identity posteriors of the hard set B_hard.
      def self.call(probs)
        mean = probs.sum.to_f
        sd = Math.sqrt(probs.sum { |p| p * (1.0 - p) })
        n = probs.length
        Result.new(mean: mean, p5: clamp(mean - Z_P05 * sd, 0.0, n), p95: clamp(mean + Z_P05 * sd, 0.0, n))
      end

      def self.clamp(value, low, high)
        value.clamp(low, high)
      end
      private_class_method :clamp
    end
  end
end
