# frozen_string_literal: true

# T1-057 FR-B2: Temporal Cross-Channel bot signal.
#
# Complements (does NOT replace) the coarse CrossChannelPresence signal (50+ channels/day). This one
# is about TEMPORAL SIMULTANEITY: a user posting in >=3 distinct channels inside a sliding <=5s window,
# REPEATED over 24h (R = recurrence count). CrossChannelIntelligenceWorker writes the per-user tier
# (watch/flag/yellow/confirmed, R>=2/3/4/7) + bot_type into cross_channel_temporal_flags; this signal
# turns the per-channel flagged subset into a [0,1] fraud value.
#
# value  = tier-weighted fraction of the channel's chatters that are SPAM-tier temporal bots.
#          Weights (ADR DEC-4, tunable via TI calibration): confirmed 1.0 / yellow 0.6 / flag 0.3 /
#          watch 0.0 (noise floor — recorded for observability but contributes nothing).
# Allowlist (BR-10): bot_type=utility (nightbot, streamelements, …) are platform bots, NOT audience
#          fraud — excluded from the numerator (a channel must not be penalised for running a mod bot).
# confidence scales with the present-chatter sample size (same shape as CrossChannelPresence).
#
# Denominator = total chatters present (context total_chatters), NOT the flagged subset — otherwise a
# couple of bots among thousands of real chatters would read as near-100% fraud.
module TrustIndex
  module Signals
    class TemporalCrossChannel < BaseSignal
      TIER_WEIGHTS = { "confirmed" => 1.0, "yellow" => 0.6, "flag" => 0.3, "watch" => 0.0 }.freeze
      CONFIDENCE_FULL_AT = 50.0

      def name = "Temporal Cross-Channel Co-occurrence"
      def signal_type = "temporal_cross_channel"

      def calculate(context)
        data = context[:temporal_cross_channel_flags] || {}
        total = data[:total_chatters].to_i
        return insufficient(reason: "no_temporal_data") if total.zero?

        flagged = data[:flagged] || {}
        # Allowlist: utility platform bots are not audience fraud (BR-10) — keep them out of the value.
        spam = flagged.reject { |_, d| d[:bot_type] == "utility" }

        weighted = spam.sum { |_, d| TIER_WEIGHTS.fetch(d[:bot_flag_tier], 0.0) }
        value = weighted / total
        confidence = [ 1.0, total / CONFIDENCE_FULL_AT ].min

        result(
          value: value,
          confidence: confidence,
          metadata: {
            total_chatters: total,
            spam_flagged: spam.size,
            utility_excluded: flagged.size - spam.size,
            confirmed: spam.count { |_, d| d[:bot_flag_tier] == "confirmed" },
            yellow: spam.count { |_, d| d[:bot_flag_tier] == "yellow" }
          }
        )
      end
    end
  end
end
