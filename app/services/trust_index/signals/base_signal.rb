# frozen_string_literal: true

# TASK-028 FR-012: BaseSignal abstract class.
# All 11 signal classes inherit from this.
# Interface: #calculate(context) → {value: Float|nil, confidence: Float}
# Thresholds and weights read from DB (FR-015) via SignalConfiguration.

module TrustIndex
  module Signals
    class BaseSignal
      Result = Data.define(:value, :confidence, :metadata)

      def name
        raise NotImplementedError, "#{self.class}#name"
      end

      def signal_type
        raise NotImplementedError, "#{self.class}#signal_type"
      end

      def weight(category = "default")
        config_value("weight_in_ti", category)
      end

      def calculate(context)
        raise NotImplementedError, "#{self.class}#calculate"
      end

      private

      def config_value(param_name, category)
        SignalConfiguration.value_for(signal_type, category, param_name)
      end

      def config_params(category)
        SignalConfiguration.params_for(signal_type, category)
      end

      def insufficient(reason: nil)
        Result.new(value: nil, confidence: 0.0, metadata: { insufficient: true, reason: reason })
      end

      def result(value:, confidence:, metadata: {})
        clamped_value = value.nil? ? nil : value.to_f.clamp(0.0, 1.0)
        clamped_confidence = confidence.to_f.clamp(0.0, 1.0)
        Result.new(value: clamped_value, confidence: clamped_confidence, metadata: metadata)
      end
    end
  end
end
