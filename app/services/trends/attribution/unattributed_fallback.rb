# frozen_string_literal: true

# TASK-039 FR-023: Fallback adapter — always matches, lowest priority (999).
#
# Guarantees anomaly имеет as least одну attribution row. Pipeline iterates sources
# ordered by priority ASC — Unattributed runs LAST. Upstream enabled sources
# (Raid, PlatformCleanup, future IGDB/Helix/Twitter) matched first при совпадении.
#
# "Unattributed" source — expected state для anomaly where no known cause
# identifiable (pure organic spike, analyst review needed). Confidence=1.0
# reflects certainty that no other source matched.

module Trends
  module Attribution
    class UnattributedFallback < BaseAdapter
      protected

      def build_attribution(anomaly)
        {
          source: "unattributed",
          confidence: 1.0,
          raw_source_data: {
            anomaly_id: anomaly.id,
            anomaly_type: anomaly.anomaly_type,
            timestamp: anomaly.timestamp.iso8601
          }
        }
      end
    end
  end
end
