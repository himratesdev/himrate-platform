# frozen_string_literal: true

# TASK-038 FR-014 / AR-06 / AR-09: Load per-category weights from SignalConfiguration.
# DB-only source (no hardcoded DEFAULT_WEIGHTS fallback). Batch-cached per request.
# Raises if configuration missing (force seeded state).

module Hs
  class WeightsLoader
    COMPONENTS = %i[ti stability engagement growth consistency].freeze

    class MissingWeights < StandardError; end

    def initialize
      @cache = {}
    end

    # Load weights for a category key. Falls back to default.
    # Returns: { ti: 0.30, stability: 0.15, engagement: 0.30, growth: 0.10, consistency: 0.15 }
    def call(category_key)
      key = category_key.to_s.presence || "default"
      @cache[key] ||= load_weights(key)
    end

    # Load cache version for invalidation keying.
    def version_for(category_key)
      SignalConfiguration
        .where(signal_type: "health_score", category: category_key)
        .maximum(:updated_at)&.to_i || 0
    end

    private

    def load_weights(category_key)
      rows = SignalConfiguration
        .where(signal_type: "health_score", category: category_key)
        .where("param_name LIKE ?", "weight_%")
        .pluck(:param_name, :param_value)
        .to_h

      if rows.empty? && category_key != "default"
        # Fallback to default category
        return call("default")
      end

      raise MissingWeights, "No weights configured for category=#{category_key}" if rows.empty?

      COMPONENTS.each_with_object({}) do |comp, hash|
        value = rows["weight_#{comp}"]
        raise MissingWeights, "Missing weight_#{comp} for category=#{category_key}" unless value

        hash[comp] = value.to_f
      end
    end
  end
end
