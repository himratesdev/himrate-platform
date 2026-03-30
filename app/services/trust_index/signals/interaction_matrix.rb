# frozen_string_literal: true

# TASK-028 FR-016: Signal Interaction Matrix.
# Combinations of signals amplify or dampen each other.
# Rules loaded from signal_configurations (param_name prefix: "interaction_").

module TrustIndex
  module Signals
    class InteractionMatrix
      # Default interaction rules (amplification / dampening).
      # Format: [condition_signal, condition_threshold, target_signal, target_threshold, multiplier]
      DEFAULT_RULES = [
        # Low CPS (vulnerable) + known bots → amplify known_bot signal
        { condition: "channel_protection_score", cond_min: 0.7,
          target: "known_bot_match", target_min: 0.05, multiplier: 1.3 },

        # Low CPS + cross-channel presence → amplify cross_channel
        { condition: "channel_protection_score", cond_min: 0.7,
          target: "cross_channel_presence", target_min: 0.05, multiplier: 1.3 },

        # CCV step function + CCV-chat divergence → both amplified
        { condition: "ccv_step_function", cond_min: 0.5,
          target: "ccv_chat_correlation", target_min: 0.3, multiplier: 1.2 },

        # Raid attribution explains CCV spike → dampen step function
        { condition: "raid_attribution", cond_min: 0.3,
          target: "ccv_step_function", target_min: 0.3, multiplier: 0.5 }
      ].freeze

      # Apply interaction rules to computed signal results.
      # Modifies values in-place (clamps 0-1).
      # Returns modified results hash + list of applied interactions.
      def self.apply(results)
        interactions_applied = []

        rules.each do |rule|
          cond_result = results[rule[:condition]]
          target_result = results[rule[:target]]

          next unless cond_result && target_result
          next unless cond_result.value && target_result.value
          next if cond_result.value < rule[:cond_min]
          next if target_result.value < rule[:target_min]

          old_value = target_result.value
          new_value = (old_value * rule[:multiplier]).clamp(0.0, 1.0)

          results[rule[:target]] = BaseSignal::Result.new(
            value: new_value,
            confidence: target_result.confidence,
            metadata: target_result.metadata.merge(
              interaction_applied: true,
              interaction_from: rule[:condition],
              original_value: old_value,
              multiplier: rule[:multiplier]
            )
          )

          interactions_applied << {
            condition: rule[:condition],
            target: rule[:target],
            multiplier: rule[:multiplier],
            old_value: old_value.round(4),
            new_value: new_value.round(4)
          }
        end

        { results: results, interactions: interactions_applied }
      end

      # Rules source: DEFAULT_RULES constant.
      # Multipliers are overridable via signal_configurations:
      #   signal_type: "interaction", category: "cps_known_bot", param_name: "multiplier", param_value: 1.3
      def self.rules
        DEFAULT_RULES.map do |rule|
          config_key = "#{rule[:condition]}_#{rule[:target]}"
          override = SignalConfiguration.find_by(
            signal_type: "interaction", category: config_key, param_name: "multiplier"
          )
          override ? rule.merge(multiplier: override.param_value.to_f) : rule
        end
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("InteractionMatrix: DB lookup failed (#{e.message}), using defaults")
        DEFAULT_RULES
      end
    end
  end
end
