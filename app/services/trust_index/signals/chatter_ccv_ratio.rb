# frozen_string_literal: true

# TASK-028 FR-002: Chatter-to-CCV Ratio signal.
# Unique IRC chatters (60min) / CCV. Category-adjusted.

module TrustIndex
  module Signals
    class ChatterCcvRatio < BaseSignal
      def name = "Chatter-to-CCV Ratio"
      def signal_type = "chatter_ccv_ratio"

      def calculate(context)
        ccv = context[:latest_ccv]
        unique_chatters_60min = context[:unique_chatters_60min]
        category = context[:category] || "default"
        stream_duration_min = context[:stream_duration_min] || 0

        return insufficient(reason: "no_ccv") unless ccv&.positive?
        return insufficient(reason: "no_irc_data") unless unique_chatters_60min

        ratio = unique_chatters_60min.to_f / ccv
        params = config_params(category)
        expected_min = params["expected_ratio_min"]&.to_f || 0.10

        if ratio >= expected_min
          value = 0.0
        else
          value = (expected_min - ratio) / expected_min
        end

        confidence = if stream_duration_min >= 30 && ccv >= 50
                       1.0
        elsif stream_duration_min >= 10
                       0.5
        else
                       0.2
        end

        result(
          value: value,
          confidence: confidence,
          metadata: { ratio: ratio.round(4), expected_min: expected_min, unique_chatters: unique_chatters_60min, ccv: ccv }
        )
      end
    end
  end
end
