# frozen_string_literal: true

# TASK-038 FR-017 / AR-07: 10 rule-based recommendations from BFT §10.1.
# Conditions remain as Ruby lambdas (eval of DB strings = security risk).
# Metadata (i18n_key, expected_impact, cta_action, enabled) loaded from RecommendationTemplate.

module Hs
  module RecommendationRules
    # Rule definition: rule_id → condition lambda
    # Context passed to lambda:
    #   components: { ti:, stability:, engagement:, growth:, consistency: }
    #   components_percentile: { ti: 72, ... } (may be nil if not enough data)
    #   ti_drop_pts: numeric (latest TI - TI 7d ago, may be nil)
    #   latest_ti: numeric
    CONDITIONS = {
      "R-01" => ->(ctx) { # Eng < p40 AND >= p20
        p = ctx[:components_percentile]&.dig(:engagement)
        p && p < 40 && p >= 20
      },
      "R-02" => ->(ctx) { # Eng < p20
        p = ctx[:components_percentile]&.dig(:engagement)
        p && p < 20
      },
      "R-03" => ->(ctx) { # Consistency < 50 AND >= 30
        v = ctx[:components]&.dig(:consistency)
        v && v < 50 && v >= 30
      },
      "R-04" => ->(ctx) { # Consistency < 30
        v = ctx[:components]&.dig(:consistency)
        v && v < 30
      },
      "R-05" => ->(ctx) { # Stability low (score < 50 = CV > 0.50)
        v = ctx[:components]&.dig(:stability)
        v && v < 50
      },
      "R-06" => ->(ctx) { # Growth < 30
        v = ctx[:components]&.dig(:growth)
        v && v < 30 && ctx[:followers_delta].to_i >= 0
      },
      "R-07" => ->(ctx) { # Growth negative (Δfollowers < 0)
        ctx[:followers_delta] && ctx[:followers_delta] < 0
      },
      "R-08" => ->(ctx) { # TI drop > configured threshold
        drop = ctx[:ti_drop_pts]
        threshold = ctx[:ti_drop_threshold]&.abs || 15
        drop && drop <= -threshold
      },
      "R-09" => ->(ctx) { # TI < 50 (penalty active)
        ti = ctx[:latest_ti]
        ti && ti < 50
      },
      "R-10" => ->(ctx) { # All components > 80
        comp = ctx[:components]
        comp && comp.values.compact.size >= 3 && comp.values.compact.all? { |v| v > 80 }
      }
    }.freeze

    # Priority ordering: critical > high > medium > low
    PRIORITY_ORDER = { "critical" => 0, "high" => 1, "medium" => 2, "low" => 3 }.freeze

    def self.evaluate(rule_id, context)
      lambda = CONDITIONS[rule_id]
      return false unless lambda

      lambda.call(context)
    rescue StandardError => e
      Rails.logger.error("RecommendationRules#evaluate: #{rule_id} failed: #{e.message}")
      false
    end
  end
end
