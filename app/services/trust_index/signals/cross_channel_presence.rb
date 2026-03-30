# frozen_string_literal: true

# TASK-028 FR-007: Cross-Channel Bot Presence signal.
# % chatters present in 50+ channels/day = confirmed bots.
# 30-50 channels = suspicious. Tiered thresholds from BFT §5.7.

module TrustIndex
  module Signals
    class CrossChannelPresence < BaseSignal
      CONFIRMED_BOT_CHANNELS = 50
      SUSPICIOUS_CHANNELS = 30

      def name = "Cross-Channel Bot Presence"
      def signal_type = "cross_channel_presence"

      def calculate(context)
        cross_channel_counts = context[:cross_channel_counts] || {}

        return insufficient(reason: "no_cross_channel_data") if cross_channel_counts.empty?

        total = cross_channel_counts.size
        bots_50plus = cross_channel_counts.count { |_, count| count >= CONFIRMED_BOT_CHANNELS }
        suspicious_30plus = cross_channel_counts.count { |_, count| count >= SUSPICIOUS_CHANNELS && count < CONFIRMED_BOT_CHANNELS }

        value = bots_50plus.to_f / total + suspicious_30plus.to_f / total * 0.3
        confidence = [ 1.0, total / 50.0 ].min

        result(
          value: value,
          confidence: confidence,
          metadata: {
            total_chatters: total, bots_50plus: bots_50plus,
            suspicious_30plus: suspicious_30plus
          }
        )
      end
    end
  end
end
