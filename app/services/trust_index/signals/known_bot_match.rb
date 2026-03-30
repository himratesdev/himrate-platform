# frozen_string_literal: true

# TASK-028 FR-008: Known Bot List Match signal.
# % chatters matching known bot databases (from per_user_bot_scores components).

module TrustIndex
  module Signals
    class KnownBotMatch < BaseSignal
      def name = "Known Bot List Match"
      def signal_type = "known_bot_match"

      def calculate(context)
        bot_scores = context[:bot_scores] || []

        return insufficient(reason: "no_bot_scores") if bot_scores.empty?

        total = bot_scores.size
        known_bots = bot_scores.count do |s|
          components = s[:components] || {}
          components.key?("known_bot_single") || components.key?("known_bot_multi") ||
            components.key?(:known_bot_single) || components.key?(:known_bot_multi)
        end

        value = known_bots.to_f / total
        confidence = [ 1.0, total / 50.0 ].min

        result(
          value: value,
          confidence: confidence,
          metadata: { total_chatters: total, known_bots: known_bots }
        )
      end
    end
  end
end
