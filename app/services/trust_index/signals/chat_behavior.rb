# frozen_string_literal: true

# TASK-028 FR-005: Per-User Chat Behavior signal.
# Weighted mean aggregation of per_user_bot_scores (not simple classification counting).
# QDC v1.1: weighted_mean * 0.6 + confirmed_ratio * 0.4.

module TrustIndex
  module Signals
    class ChatBehavior < BaseSignal
      def name = "Per-User Chat Behavior"
      def signal_type = "chat_behavior"

      def calculate(context)
        bot_scores = context[:bot_scores] || []

        return insufficient(reason: "no_bot_scores") if bot_scores.empty?

        total = bot_scores.size
        confirmed = bot_scores.count { |s| s[:classification] == "confirmed_bot" }
        confirmed_ratio = confirmed.to_f / total

        # Weighted mean: sum(score * confidence) / sum(confidence)
        weighted_sum = bot_scores.sum { |s| s[:bot_score].to_f * s[:confidence].to_f }
        total_weight = bot_scores.sum { |s| s[:confidence].to_f }

        weighted_mean = total_weight.positive? ? weighted_sum / total_weight : 0.0

        value = weighted_mean * 0.6 + confirmed_ratio * 0.4
        confidence = [ 1.0, total / 50.0 ].min * (total_weight.positive? ? [ 1.0, total_weight / total ].min : 0.5)

        # TASK-085 FR-017 (ADR-085 D-7): Shannon entropy_bits для chat_entropy_drop alert.
        # AnomalyAlerter line 36 forwards signal_metadata → Anomaly#details automatically.
        # Trust::AnomalyAlertsPresenter reads anomaly.details.dig('signal_metadata', 'entropy_bits')
        # для chat_entropy_drop derivation (zero extra query, D-7 simplification override SA).
        username_counts = (context[:chat_username_counts_5min] || {}).values
        entropy_bits = ShannonEntropy.compute(username_counts).round(2)

        result(
          value: value,
          confidence: confidence,
          metadata: {
            total_chatters: total, confirmed_bots: confirmed,
            weighted_mean: weighted_mean.round(4), confirmed_ratio: confirmed_ratio.round(4),
            total_weight: total_weight.round(2),
            entropy_bits: entropy_bits
          }
        )
      end
    end
  end
end
