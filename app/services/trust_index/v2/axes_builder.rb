# frozen_string_literal: true

module TrustIndex
  module V2
    # The 3 ORTHOGONAL axes, NEVER averaged into one number (SRS FR-006/007, BR-002). Authenticity
    # (0-100) drives the label; Reputation is a categorical prior on variance (delegated to the
    # Reputation domain — Безупречная/Стабильная/Изменчивая/Нестабильная); Engagement-context is
    # purely descriptive (chat share ρ_obs, CPS). CPS lives HERE, evicted from the fraud score (BR-012).
    class AxesBuilder
      Axes = Data.define(:authenticity, :reputation, :engagement_context)

      # authenticity — L4 A (0-100). reputation — categorical band from the Reputation domain (or nil
      # if unavailable). rho_obs — L2 observed chat share. cps — Channel Protection Score (0-100 or nil).
      def self.call(authenticity:, reputation:, rho_obs:, cps:)
        Axes.new(
          authenticity: authenticity,
          reputation: reputation,
          engagement_context: { chat_share: rho_obs, cps: cps }
        )
      end
    end
  end
end
