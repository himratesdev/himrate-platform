# frozen_string_literal: true

# TASK-085 FR-017 (ADR-085 D-7): Shannon entropy helper для chat_entropy_drop detection.
# Computes H = -sum(p_i * log2(p_i)) where p_i = count_i / total.
# Used by ChatBehavior signal (chat message username distribution per 5min window).
# Result в bits — threshold 2.0 для chat_entropy_drop alert (red severity per BR-010).

module TrustIndex
  module Signals
    module ShannonEntropy
      # Compute Shannon entropy в bits для array of frequency counts.
      # Returns 0.0 для empty input or all-zero counts (no information).
      # For N equally distributed categories returns log2(N).
      def self.compute(counts)
        return 0.0 if counts.empty?

        total = counts.sum.to_f
        return 0.0 if total.zero?

        -counts.sum do |count|
          probability = count / total
          probability.positive? ? probability * Math.log2(probability) : 0.0
        end
      end
    end
  end
end
