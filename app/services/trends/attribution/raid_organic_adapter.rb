# frozen_string_literal: true

# TASK-039 FR-021: RaidOrganic attribution — non-bot raid events.
#
# CR N-1: 1:1 source-adapter mapping per ADR §4.14 — separate class от
# RaidBotAdapter чтобы avoid 2× invocation Pipeline overhead (shared adapter
# called per source entry, redundant compute).
#
# Filters RaidAttribution WHERE is_bot_raid=false. Confidence по default
# значение 0.8 (organic raids не имеют bot_score, confidence отражает
# certainty matching — raid occurred, anomaly likely explained by it).

module Trends
  module Attribution
    class RaidOrganicAdapter < BaseAdapter
      SIGNAL_TYPE = "trust_index"
      CONFIG_CATEGORY = "raid_attribution"

      protected

      def build_attribution(anomaly)
        raid = RaidAttribution
          .where(stream_id: anomaly.stream_id, is_bot_raid: false)
          .order(timestamp: :desc)
          .first
        return nil if raid.nil?

        {
          source: "raid_organic",
          confidence: organic_confidence,
          raw_source_data: {
            raid_attribution_id: raid.id,
            source_channel_id: raid.source_channel_id,
            raid_viewers_count: raid.raid_viewers_count,
            raid_timestamp: raid.timestamp.iso8601
          }
        }
      end

      private

      # PG O-1: admin tunable — default 0.8 reflects matching certainty.
      def organic_confidence
        @organic_confidence ||= SignalConfiguration.value_for(
          SIGNAL_TYPE, CONFIG_CATEGORY, "raid_organic_default_confidence"
        ).to_f
      end
    end
  end
end
