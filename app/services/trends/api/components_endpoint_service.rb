# frozen_string_literal: true

# TASK-039 FR-005: GET /api/v1/channels/:id/trends/components — M5 Component Breakdown.
# Response per SRS §4.4 extended: points + degradation_signals + discovery_phase + coupling_timeline + botted_fraction.
#
# Group filter (SRS US-014):
#   - nil (default): all 14 components (11 live signals + 3 reputation)
#   - "live_signals": 11 live signals
#   - "streamer_reputation": 3 reputation components
#   - "core": top-5 для mobile compact view

module Trends
  module Api
    class ComponentsEndpointService < BaseEndpointService
      LIVE_SIGNALS = %w[
        auth_ratio chatter_to_ccv ccv_step_function ccv_tier_clustering
        chat_behavior channel_protection_score cross_channel_presence
        known_bot_match raid_attribution ccv_chat_correlation account_profile_scoring
      ].freeze

      REPUTATION_COMPONENTS = %w[growth_rate follower_quality engagement_consistency].freeze

      def initialize(channel:, period:, granularity: nil, group: nil)
        super(channel: channel, period: period, granularity: granularity)
        @group = group
      end

      def call
        from_ts, to_ts = range
        points = build_points(from_ts, to_ts)
        degradation = compute_degradation_signals(points)
        discovery_phase = Trends::Analysis::DiscoveryPhaseDetector.call(channel)
        coupling = Trends::Analysis::FollowerCcvCouplingTimeline.call(
          channel_id: channel.id, from: from_ts.to_date, to: to_ts.to_date
        )
        botted_fraction = compute_botted_fraction(from_ts, to_ts)

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            group: @group,
            components: active_components,
            points: points,
            degradation_signals: degradation,
            discovery_phase: discovery_phase,
            follower_ccv_coupling_timeline: coupling[:timeline],
            follower_ccv_coupling_summary: coupling[:summary],
            botted_fraction: botted_fraction
          },
          meta: meta
        }
      end

      private

      def active_components
        case @group
        when "live_signals" then LIVE_SIGNALS
        when "streamer_reputation" then REPUTATION_COMPONENTS
        when "core" then LIVE_SIGNALS.first(3) + REPUTATION_COMPONENTS.first(2)
        else LIVE_SIGNALS + REPUTATION_COMPONENTS
        end
      end

      def build_points(from_ts, to_ts)
        TrustIndexHistory
          .for_channel(channel.id)
          .where(calculated_at: from_ts..to_ts)
          .where.not(signal_breakdown: [ nil, {} ])
          .order(:calculated_at)
          .pluck(:calculated_at, :trust_index_score, :signal_breakdown)
          .map { |ts, ti, breakdown| point_for(ts, ti, breakdown) }
      end

      def point_for(ts, ti, breakdown)
        filtered = breakdown.slice(*active_components)
        {
          date: ts.iso8601,
          ti: ti&.to_f&.round(2),
          components: filtered.transform_values { |v| sanitize_component_value(v) }
        }
      end

      def sanitize_component_value(value)
        case value
        when Hash then value.slice("value", "confidence").transform_values { |v| v.is_a?(Numeric) ? v.to_f.round(3) : v }
        when Numeric then value.to_f.round(3)
        else value
        end
      end

      # Degradation = components с наибольшим negative delta между first and last points (Top-3).
      def compute_degradation_signals(points)
        return [] if points.size < 2

        first = points.first[:components]
        last = points.last[:components]

        active_components.filter_map do |comp|
          f = extract_value(first[comp])
          l = extract_value(last[comp])
          next nil if f.nil? || l.nil?

          delta = (l - f).round(3)
          { name: comp, delta: delta, start_value: f, end_value: l }
        end
        .sort_by { |s| s[:delta] }
        .first(3)
      end

      def extract_value(component_value)
        case component_value
        when Hash then component_value["value"]&.to_f
        when Numeric then component_value.to_f
        end
      end

      def compute_botted_fraction(from_ts, to_ts)
        avg = TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where.not(botted_fraction: nil)
          .average(:botted_fraction)

        avg&.to_f&.round(3)
      end
    end
  end
end
