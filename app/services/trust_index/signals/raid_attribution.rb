# frozen_string_literal: true

# TASK-028 FR-009: Raid Attribution signal.
# Probabilistic 5-signal stack for raid bot detection.
# No raids = value 0.0 (clean). Raids present = probabilistic assessment.

module TrustIndex
  module Signals
    class RaidAttribution < BaseSignal
      def name = "Raid Attribution"
      def signal_type = "raid_attribution"

      def calculate(context)
        raids = context[:raids] || []
        ccv_series = context[:ccv_series_15min] || []

        # No raids = clean stream (good signal)
        return result(value: 0.0, confidence: 1.0, metadata: { raids: 0 }) if raids.empty?

        bot_raid_score = 0.0
        raid_details = []

        raids.each do |raid|
          raid_score = assess_raid(raid, ccv_series)
          bot_raid_score += raid_score[:value]
          raid_details << raid_score
        end

        # Probabilistic — never full confidence with raids
        confidence = 0.7

        result(
          value: bot_raid_score,
          confidence: confidence,
          metadata: { raids_count: raids.size, raid_details: raid_details }
        )
      end

      private

      def assess_raid(raid, ccv_series)
        signals = []

        # Signal 1: EventSub anchor (raid exists)
        signals << { name: "eventsub_anchor", value: 1.0 }

        # Signal 2: CCV delta magnitude
        ccv_delta = estimate_ccv_delta(raid, ccv_series)
        delta_signal = ccv_delta.positive? ? [ 1.0, ccv_delta / 1000.0 ].min : 0.0
        signals << { name: "ccv_delta", value: delta_signal }

        # Signal 3: Is bot raid (from raid_attributions table)
        bot_raid_signal = raid[:is_bot_raid] ? 0.8 : 0.0
        signals << { name: "is_bot_raid", value: bot_raid_signal }

        # Signal 4: Historical pattern (source channel)
        # Simplified: use bot_score from raid_attributions if available
        historical = raid[:bot_score]&.to_f || 0.0
        signals << { name: "historical_pattern", value: historical }

        # Combined: weighted average of signals
        total = signals.sum { |s| s[:value] } / signals.size

        { value: total.clamp(0.0, 1.0), signals: signals, raid_viewers: raid[:raid_viewers_count] }
      end

      def estimate_ccv_delta(raid, ccv_series)
        raid_time = raid[:timestamp]
        return 0 unless raid_time && ccv_series.size >= 2

        before = ccv_series.select { |s| s[:timestamp] < raid_time }.last
        after = ccv_series.select { |s| s[:timestamp] >= raid_time }.first

        return 0 unless before && after

        (after[:ccv] - before[:ccv]).abs
      end
    end
  end
end
