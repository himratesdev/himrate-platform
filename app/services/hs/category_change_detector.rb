# frozen_string_literal: true

# TASK-038 FR-033: Emit category change event when channel switches Twitch category.
# Dual-purpose table (hs_tier_change_events) with event_type="category_change".

module Hs
  class CategoryChangeDetector
    def call(channel:, new_hs_record:)
      return nil unless new_hs_record.category

      previous_category = HealthScore
        .where(channel_id: channel.id)
        .where.not(id: new_hs_record.id)
        .where.not(category: nil)
        .order(calculated_at: :desc)
        .pick(:category)

      return nil if previous_category.nil? || previous_category == new_hs_record.category

      HsTierChangeEvent.create!(
        channel_id: channel.id,
        stream_id: new_hs_record.stream_id,
        event_type: "category_change",
        from_tier: "category:#{previous_category}",
        to_tier: "category:#{new_hs_record.category}",
        hs_before: nil,
        hs_after: new_hs_record.health_score,
        occurred_at: new_hs_record.calculated_at,
        metadata: {
          previous_category: previous_category,
          new_category: new_hs_record.category
        }
      )
    end
  end
end
