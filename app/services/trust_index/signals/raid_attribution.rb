# frozen_string_literal: true

# TASK-028 FR-009 / TASK-251.B: Raid Attribution signal (#9).
#
# Reads RaidAttribution records (written by RaidDetectionWorker, TASK-251.B) and contributes the
# already-calibrated bot fraction of CONFIRMED bot-raids only. Organic / non-significant raids
# contribute 0.0 — *getting raided is not itself evidence of bots*. The worker's significance-gated
# signal stack (write_rate / account_age / cross_channel / ccv-decay) is the single source of truth
# for is_bot_raid + bot_score; this signal must not re-penalise on mere raid existence, which would
# re-introduce the "always-fire" mistake the worker deliberately avoids (cf. #11 calibration).
#
# No raids, or raids but none classified as bot-raids → 0.0 (clean, confidence 1.0).
module TrustIndex
  module Signals
    class RaidAttribution < BaseSignal
      CONFIDENCE = 0.7 # probabilistic — never full confidence once bots are implicated

      def name = "Raid Attribution"
      def signal_type = "raid_attribution"

      def calculate(context)
        raids = context[:raids] || []
        bot_raids = raids.select { |raid| raid[:is_bot_raid] }
        return clean(raids.size) if bot_raids.empty?

        # Sum the worker-calibrated bot_score of confirmed bot-raids (BaseSignal#result clamps to [0,1]).
        value = bot_raids.sum { |raid| raid[:bot_score].to_f }
        result(
          value: value,
          confidence: CONFIDENCE,
          metadata: { raids: raids.size, bot_raids: bot_raids.size, bot_score_total: value.round(4) }
        )
      end

      private

      def clean(raids_count)
        result(value: 0.0, confidence: 1.0, metadata: { raids: raids_count, bot_raids: 0 })
      end
    end
  end
end
