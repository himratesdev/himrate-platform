# frozen_string_literal: true

# TASK-039 FR-010 (NEW v2.0): GET /api/v1/channels/:id/trends/insights — MovementInsights orchestrator.
# Response per SRS §4.2: top-N insights (P0/P1/P2) с i18n messages + action deep-links.
#
# Aggregates inputs from 4 sources:
#   - TrendCalculator (на TI points) — direction + delta
#   - AnomalyFrequencyScorer — elevated/reduced verdict + delta_percent
#   - TierChangeCounter — recent tier changes
#   - RehabilitationTracker (optional) — active rehabilitation + bonus
#
# Передаются в Trends::Analysis::MovementInsights которая делает priority ranking + i18n.

module Trends
  module Api
    class InsightsEndpointService < BaseEndpointService
      def call
        from_ts, to_ts = range

        ti_points = load_ti_points(from_ts, to_ts)
        trend = compute_trend(ti_points)
        anomaly_freq = Trends::Analysis::AnomalyFrequencyScorer.call(channel: channel, from: from_ts, to: to_ts)
        tier_changes = Trends::Analysis::TierChangeCounter.call(channel: channel, from: from_ts, to: to_ts)
        rehabilitation = TrustIndex::RehabilitationTracker.call(channel)
        top_improvement, top_degradation = extract_top_signals(from_ts, to_ts)

        insights = Trends::Analysis::MovementInsights.call(
          channel: channel, from: from_ts, to: to_ts,
          trend: trend,
          anomaly_frequency: anomaly_freq,
          tier_changes: tier_changes,
          rehabilitation: rehabilitation,
          top_improvement: top_improvement,
          top_degradation: top_degradation
        )

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            insights: insights
          },
          meta: meta
        }
      end

      private

      def load_ti_points(from_ts, to_ts)
        TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where.not(ti_avg: nil)
          .order(:date)
          .pluck(:date, :ti_avg)
          .map { |date, ti| { date: date, ti: ti.to_f } }
      end

      def compute_trend(points)
        return empty_trend(n_points: points.size) if points.size < min_points_for_trend

        series = points.each_with_index.map { |p, i| [ i.to_f, p[:ti] ] }
        Trends::Analysis::TrendCalculator.call(series)
      end

      # Extracts top improvement + top degradation signals по delta между first and last TI point.
      # Computation делегируется downstream signal compute (B3 components service уже делает аналог).
      # Здесь simplification — nil если <2 points, позволяет MovementInsights использовать fallback.
      def extract_top_signals(from_ts, to_ts)
        rows = TrustIndexHistory
          .for_channel(channel.id)
          .where(calculated_at: from_ts..to_ts)
          .where("signal_breakdown IS NOT NULL AND signal_breakdown <> '{}'::jsonb")
          .order(:calculated_at)
          .pluck(:calculated_at, :signal_breakdown)

        return [ nil, nil ] if rows.size < 2

        first_breakdown = rows.first.last
        last_breakdown = rows.last.last

        deltas = common_component_deltas(first_breakdown, last_breakdown)
        return [ nil, nil ] if deltas.empty?

        sorted = deltas.sort_by { |_, delta| delta }
        top_degradation = sorted.first.then { |k, v| v.negative? ? { name: k, delta: v } : nil }
        top_improvement = sorted.last.then { |k, v| v.positive? ? { name: k, delta: v } : nil }

        [ top_improvement, top_degradation ]
      end

      def common_component_deltas(first, last)
        first.keys.each_with_object({}) do |component, deltas|
          next unless last.key?(component)

          f = extract_value(first[component])
          l = extract_value(last[component])
          next if f.nil? || l.nil?

          deltas[component] = (l - f).round(3)
        end
      end

      def extract_value(component_value)
        case component_value
        when Hash then component_value["value"]&.to_f
        when Numeric then component_value.to_f
        end
      end
    end
  end
end
