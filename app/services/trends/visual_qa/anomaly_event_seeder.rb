# frozen_string_literal: true

# TASK-039 Visual QA: creates Anomaly events на random streams — feeds M4 Anomaly Events.
# Distributes evenly: каждая anomaly attached к отдельной stream (older 2/3 of period).
# Confidence 0.7+ (passes min_confidence_threshold) для visibility в AnomalyFrequencyScorer.

module Trends
  module VisualQa
    class AnomalyEventSeeder
      # TASK-085 FR-019 (ADR-085 D-2): bot_wave → anomaly_wave (legal-safe).
      ANOMALY_TYPES = %w[anomaly_wave viewbot_spike organic_spike ccv_step_function auth_ratio].freeze

      def self.seed(channel:, streams:, count:)
        new(channel: channel, streams: streams, count: count).seed
      end

      def initialize(channel:, streams:, count:)
        @channel = channel
        @streams = streams
        @count = count
      end

      def seed
        return [] if @streams.empty? || @count <= 0

        # Evenly spaced through older 2/3 of streams (newer streams "clean" by design).
        pool_size = (@streams.size * 2 / 3).clamp(1, @streams.size)
        stride = [ (pool_size / @count).to_i, 1 ].max

        (0...@count).map do |i|
          stream_idx = [ (i * stride), pool_size - 1 ].min
          stream = @streams[stream_idx]
          next unless stream

          # Idempotent via (stream_id, anomaly_type) — re-run не создаёт dup.
          anomaly_type = ANOMALY_TYPES[i % ANOMALY_TYPES.size]
          Anomaly.find_or_create_by!(stream_id: stream.id, anomaly_type: anomaly_type) do |a|
            a.timestamp = stream.started_at + 30.minutes
            a.cause = "vqa_synthetic"
            a.confidence = 0.75 + (i * 0.05).clamp(0, 0.2)
            a.ccv_impact = 200 + (i * 50)
            a.details = { source: "visual_qa_seeder", iteration: i }
          end
        end.compact
      end
    end
  end
end
