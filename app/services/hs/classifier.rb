# frozen_string_literal: true

# TASK-038 FR-009..012 / AR-08: Single source of truth for HS classification.
# Reads 5-tier palette from HealthScoreTier table.
# Used by worker (hs_classification column) + controller (API labels).

module Hs
  class Classifier
    class << self
      # Returns tier hash or nil
      def for(score)
        tier = HealthScoreTier.for_score(score)
        return nil unless tier

        {
          key: tier.key,
          color: tier.color_name,
          bg_hex: tier.bg_hex,
          text_hex: tier.text_hex,
          i18n_key: tier.i18n_key,
          min_score: tier.min_score,
          max_score: tier.max_score
        }
      end

      # Returns key string ("excellent", "good", ...) or nil
      def classification(score)
        HealthScoreTier.for_score(score)&.key
      end

      # Localized label via i18n
      def label(score, locale: I18n.locale)
        tier = HealthScoreTier.for_score(score)
        return nil unless tier

        I18n.t(tier.i18n_key, locale: locale, default: tier.key.humanize)
      end
    end
  end
end
