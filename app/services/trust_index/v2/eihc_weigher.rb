# frozen_string_literal: true

module TrustIndex
  module V2
    # L2 per-chatter effective weight w(u) = g_density(cluster) · age_gate(u) · recurrence_gate(u)
    # (SRS FR-003, Glossary «EIHC» / «δ_K / τ_δ»). A bot-dense co-viewing cluster (δ_K ≥ τ_δ) collapses
    # to 1/|K| (density gate, NOT a ≥2-ID count gate that false-positived raids); an honest superfan
    # community (δ_K < τ_δ) keeps full weight. age/recurrence gates ∈ [0,1] downweight fresh /
    # non-recurring accounts. EIHC = Σ w(u) over chatters ∉ B_hard. Pure function.
    class EihcWeigher
      # chatter — responds to: cluster_delta_k, cluster_size, age_gate, recurrence_gate.
      # tau_delta — density-gate threshold (calibration constant).
      def self.weight(chatter, tau_delta:)
        g_density(chatter, tau_delta) * chatter.age_gate * chatter.recurrence_gate
      end

      # EIHC over a chatter collection already stripped of B_hard by the caller.
      def self.eihc(chatters, tau_delta:)
        chatters.sum { |c| weight(c, tau_delta: tau_delta) }
      end

      def self.g_density(chatter, tau_delta)
        return 1.0 if chatter.cluster_delta_k < tau_delta

        1.0 / [ chatter.cluster_size, 1 ].max
      end
      private_class_method :g_density
    end
  end
end
