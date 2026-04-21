# frozen_string_literal: true

# TASK-039 FR-033: Count HS tier change events в указанном периоде.
# Feeds /trends/trust-index response (tier_changes_count badge, M2 module).
# Also used by MovementInsights (FR-034) для P1 priority recency weighting.
#
# Data source: hs_tier_change_events (TASK-038 FR-030).
# Event types: tier_change, category_change, significant_drop, significant_rise.
# Default: tier_change only (matches SRS §4A "tier_changes_count" semantics).

module Trends
  module Analysis
    class TierChangeCounter
      def self.call(channel:, from:, to:, event_types: %w[tier_change])
        new(channel: channel, from: from, to: to, event_types: event_types).call
      end

      def initialize(channel:, from:, to:, event_types:)
        @channel = channel
        @from = from
        @to = to
        @event_types = event_types
      end

      def call
        events = HsTierChangeEvent
          .for_channel(@channel.id)
          .where(event_type: @event_types)
          .where(occurred_at: @from..@to)

        {
          count: events.count,
          latest: latest_summary(events)
        }
      end

      private

      def latest_summary(events)
        last = events.order(occurred_at: :desc).first
        return nil unless last

        {
          event_id: last.id,
          event_type: last.event_type,
          from_tier: last.from_tier,
          to_tier: last.to_tier,
          occurred_at: last.occurred_at,
          hs_before: last.hs_before,
          hs_after: last.hs_after
        }
      end
    end
  end
end
