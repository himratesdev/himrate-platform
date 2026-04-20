# frozen_string_literal: true

# TASK-039 FR-021: RaidBot attribution — bot-driven raid events.
#
# CR N-1: 1:1 source-adapter mapping per ADR §4.14 — separate class от
# RaidOrganicAdapter чтобы avoid 2× invocation Pipeline overhead.
#
# Filters RaidAttribution WHERE is_bot_raid=true. Confidence от bot_score
# (0..1 range, already normalized by bot_detection/raid_chain_detector).

module Trends
  module Attribution
    class RaidBotAdapter < BaseAdapter
      FALLBACK_CONFIDENCE = 0.8

      protected

      def build_attribution(anomaly)
        raid = RaidAttribution
          .where(stream_id: anomaly.stream_id, is_bot_raid: true)
          .order(timestamp: :desc)
          .first
        return nil if raid.nil?

        confidence = (raid.bot_score&.to_f || FALLBACK_CONFIDENCE).clamp(0.0, 1.0)

        {
          source: "raid_bot",
          confidence: confidence,
          raw_source_data: {
            raid_attribution_id: raid.id,
            source_channel_id: raid.source_channel_id,
            raid_viewers_count: raid.raid_viewers_count,
            bot_score: raid.bot_score&.to_f,
            raid_timestamp: raid.timestamp.iso8601
          }
        }
      end
    end
  end
end
