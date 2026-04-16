# frozen_string_literal: true

# TASK-038 FR-029: Data freshness 3-state (BR-22, BFT EC-06b).
# fresh: <48h, stale: 48h–30d, very_stale: >30d (hide HS per EC-06).

module Hs
  class DataFreshnessChecker
    STALE_THRESHOLD = 48.hours
    VERY_STALE_THRESHOLD = 30.days

    def self.call(calculated_at)
      return nil unless calculated_at

      age = Time.current - calculated_at
      if age < STALE_THRESHOLD
        "fresh"
      elsif age < VERY_STALE_THRESHOLD
        "stale"
      else
        "very_stale"
      end
    end
  end
end
