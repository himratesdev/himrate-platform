# frozen_string_literal: true

module TrustIndex
  module V2
    # The 3 ORTHOGONAL axes, NEVER averaged into one number (SRS FR-006/007, BR-002). Authenticity
    # (0-100) drives the label; Reputation is a categorical prior on variance (delegated to the
    # Reputation domain — Безупречная/Стабильная/Изменчивая/Нестабильная); Engagement-context is
    # purely descriptive (chat share ρ_obs, CPS). CPS lives HERE, evicted from the fraud score (BR-012).
    class AxesBuilder
      Axes = Data.define(:authenticity, :reputation, :engagement_context)

      # authenticity — L4 A (0-100); nested {value, interval} per SRS §4A / extension CardAxes
      # (contract-finish 2026-09 — axes.authenticity.value, NOT a bare number). reputation —
      # BandService hash {band:, tier:, stream_count:} (or nil) normalized to the wire axis
      # {tier, band, label_key}. rho_obs — L2 observed chat share. cps — Channel Protection
      # Score (0-100 or nil, null until the CPS pipeline feeds the v2 context).
      def self.call(authenticity:, reputation:, rho_obs:, cps:, authenticity_lo: nil, authenticity_hi: nil)
        Axes.new(
          authenticity: { value: authenticity, interval: { lo: authenticity_lo, hi: authenticity_hi } },
          reputation: reputation_axis(reputation),
          engagement_context: { chat_share: rho_obs, cps: cps }
        )
      end

      # Always an object (extension CardAxes requires the axis) — fields null when the
      # Reputation domain has nothing (cold start / cache miss). label_key nil: clients
      # render their own band labels (sp.rep_band.*) from `band`.
      def self.reputation_axis(rep)
        rep = {} unless rep.is_a?(Hash)
        { tier: rep[:tier], band: rep[:band], label_key: nil }
      end
    end
  end
end
