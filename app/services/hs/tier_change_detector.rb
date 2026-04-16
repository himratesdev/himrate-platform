# frozen_string_literal: true

# TASK-038 FR-032: Emit HS tier change event when classification crosses tier boundary.
# Cross-tier only (no within-tier magnitude events). Writes to hs_tier_change_events.

module Hs
  class TierChangeDetector
    def call(channel:, new_hs_record:)
      previous = HealthScore
        .where(channel_id: channel.id)
        .where.not(id: new_hs_record.id)
        .order(calculated_at: :desc)
        .first

      new_tier = new_hs_record.hs_classification
      return nil if new_tier.nil?

      # First HS record OR classification unchanged → no event
      return nil if previous.nil? || previous.hs_classification == new_tier

      HsTierChangeEvent.create!(
        channel_id: channel.id,
        stream_id: new_hs_record.stream_id,
        event_type: "tier_change",
        from_tier: previous.hs_classification,
        to_tier: new_tier,
        hs_before: previous.health_score,
        hs_after: new_hs_record.health_score,
        occurred_at: new_hs_record.calculated_at,
        metadata: {
          delta: (new_hs_record.health_score.to_f - previous.health_score.to_f).round(2)
        }
      )
    end
  end
end
