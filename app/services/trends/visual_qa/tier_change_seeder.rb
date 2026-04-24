# frozen_string_literal: true

# TASK-039 Visual QA: creates HS tier_change events — feeds M2 tier_changes badge
# + trends_daily_aggregates.tier_change_on_day populated by DailyBuilder.
#
# Spread evenly через period. Creates "needs_review → trusted" transitions
# (simulates channel improvement) — matches "rising TI" trend from TihHistorySeeder.

module Trends
  module VisualQa
    class TierChangeSeeder
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

        stride = [ (@streams.size / @count).to_i, 1 ].max

        (0...@count).map do |i|
          stream_idx = [ (i * stride), @streams.size - 1 ].min
          stream = @streams[stream_idx]
          next unless stream

          # Idempotent via (channel_id, stream_id, event_type).
          HsTierChangeEvent.find_or_create_by!(
            channel_id: @channel.id,
            stream_id: stream.id,
            event_type: "tier_change"
          ) do |e|
            e.from_tier = i.zero? ? "suspicious" : "needs_review"
            e.to_tier = i.zero? ? "needs_review" : "trusted"
            e.hs_before = 45 + i * 8
            e.hs_after = 55 + i * 10
            e.metadata = { delta: 10, source: "visual_qa_seeder" }
            e.occurred_at = stream.ended_at
          end
        end.compact
      end
    end
  end
end
