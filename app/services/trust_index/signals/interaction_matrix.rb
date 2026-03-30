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

      # Load rules from DB if available, otherwise use defaults.
      def self.rules
        db_rules = load_db_rules
        db_rules.any? ? db_rules : DEFAULT_RULES
      end

      def self.load_db_rules
        configs = SignalConfiguration.where("param_name LIKE 'interaction_%'")
        return [] if configs.empty?

        configs.group_by { |c| c.signal_type }.map do |_signal_type, group|
          params = group.each_with_object({}) { |c, h| h[c.param_name] = c.param_value.to_f }
          next unless params["interaction_condition"] && params["interaction_target"]

          {
            condition: params["interaction_condition"].to_s,
            cond_min: params["interaction_cond_min"] || 0.5,
            target: params["interaction_target"].to_s,
            target_min: params["interaction_target_min"] || 0.3,
            multiplier: params["interaction_multiplier"] || 1.0
          }
        end.compact
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("InteractionMatrix: DB rules failed (#{e.message}), using defaults")
        []
      end

      private_class_method :load_db_rules
    end
  end
end
