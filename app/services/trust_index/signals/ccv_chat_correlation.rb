# frozen_string_literal: true

# TASK-028 FR-010: CCV + Chat Rate Correlation signal.
# CCV delta >30% AND chat delta <5% = view-only bots.

module TrustIndex
  module Signals
    class CcvChatCorrelation < BaseSignal
      CCV_DELTA_THRESHOLD = 30.0   # percent
      CHAT_DELTA_THRESHOLD = 5.0   # percent

      def name = "CCV + Chat Rate Correlation"
      def signal_type = "ccv_chat_correlation"

      def calculate(context)
        ccv_series = context[:ccv_series_10min] || []
        chat_rate_series = context[:chat_rate_10min] || []

        return insufficient(reason: "no_ccv_data") if ccv_series.size < 2
        return insufficient(reason: "no_chat_data") if chat_rate_series.size < 2

        ccv_old = ccv_series.first[:ccv].to_f
        ccv_new = ccv_series.last[:ccv].to_f
        chat_old = chat_rate_series.first[:msg_count].to_f
        chat_new = chat_rate_series.last[:msg_count].to_f

        return insufficient(reason: "baseline_zero") if ccv_old.zero? || chat_old.zero?

        # Only positive CCV delta matters (bots inject viewers = CCV increase).
        # CCV decrease with stable chat = normal end-of-stream, not bots.
        ccv_delta_pct = (ccv_new - ccv_old) / ccv_old * 100
        return result(value: 0.0, confidence: 1.0, metadata: { reason: "ccv_decrease", ccv_delta_pct: ccv_delta_pct.round(2) }) if ccv_delta_pct <= 0

        chat_delta_pct = ((chat_new - chat_old) / chat_old * 100).abs

        # Divergence: CCV goes up significantly but chat doesn't follow
        value = if ccv_delta_pct > CCV_DELTA_THRESHOLD && chat_delta_pct < CHAT_DELTA_THRESHOLD
                  divergence = (ccv_delta_pct - CCV_DELTA_THRESHOLD) / 70.0 *
                    (1.0 - chat_delta_pct / CHAT_DELTA_THRESHOLD)
                  divergence.clamp(0.0, 1.0)
        else
                  0.0
        end

        confidence = ccv_old >= 50 && chat_old >= 5 ? 1.0 : 0.3

        result(
          value: value,
          confidence: confidence,
          metadata: {
            ccv_delta_pct: ccv_delta_pct.round(2), chat_delta_pct: chat_delta_pct.round(2),
            ccv_old: ccv_old.round(0), ccv_new: ccv_new.round(0),
            chat_old: chat_old.round(0), chat_new: chat_new.round(0)
          }
        )
      end
    end
  end
end
