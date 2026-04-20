# frozen_string_literal: true

# TASK-039 FR-021: Raid attribution — anomaly matches existing RaidAttribution row
# на том же stream (bot_detection/raid_chain_detector output).
#
# Source classification:
#   - "raid_bot": is_bot_raid=true, confidence от bot_score (0..1)
#   - "raid_organic": is_bot_raid=false, confidence дефолтная (0.8)
#
# Только самая recent RaidAttribution учитывается (ORDER BY timestamp DESC LIMIT 1)
# если anomaly.stream_id имеет несколько raid events — наиболее relevant к аномалии
# it is the latest одно.

module Trends
  module Attribution
    class RaidAdapter < BaseAdapter
      ORGANIC_CONFIDENCE = 0.8

      protected

      def build_attribution(anomaly)
        raid = RaidAttribution
          .where(stream_id: anomaly.stream_id)
          .order(timestamp: :desc)
          .first
        return nil if raid.nil?

        source = raid.is_bot_raid ? "raid_bot" : "raid_organic"
        confidence = raid.is_bot_raid ? (raid.bot_score&.to_f || ORGANIC_CONFIDENCE) : ORGANIC_CONFIDENCE

        {
          source: source,
          confidence: confidence.clamp(0.0, 1.0),
          raw_source_data: {
            raid_attribution_id: raid.id,
            source_channel_id: raid.source_channel_id,
            raid_viewers_count: raid.raid_viewers_count,
            bot_score: raid.bot_score&.to_f,
            is_bot_raid: raid.is_bot_raid,
            raid_timestamp: raid.timestamp.iso8601
          }
        }
      end
    end
  end
end
