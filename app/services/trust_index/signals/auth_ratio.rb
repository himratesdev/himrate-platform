# frozen_string_literal: true

# TASK-028 FR-001: Auth Ratio signal.
# chatters.count / CCV, normalized by category threshold.
# Low auth ratio = view-only bots.

module TrustIndex
  module Signals
    class AuthRatio < BaseSignal
      def name = "Auth Ratio"
      def signal_type = "auth_ratio"

      def calculate(context)
        ccv = context[:latest_ccv]
        chatters = context[:latest_chatters]
        category = context[:category] || "default"

        return insufficient(reason: "no_ccv") unless ccv&.positive?
        return insufficient(reason: "cold_start") if ccv < 3
        return insufficient(reason: "no_chatters") unless chatters&.positive?

        raw_ratio = chatters.to_f / ccv
        params = config_params(category)
        expected_min = params["expected_min"]&.to_f || 0.65

        if raw_ratio >= expected_min
          value = 0.0
        else
          value = (expected_min - raw_ratio) / expected_min
        end

        confidence = if ccv >= 50 && chatters >= 10
                       1.0
        elsif ccv >= 10
                       0.5
        else
                       0.2
        end

        result(
          value: value,
          confidence: confidence,
          metadata: { raw_ratio: raw_ratio.round(4), expected_min: expected_min, ccv: ccv, chatters: chatters }
        )
      end
    end
  end
end
