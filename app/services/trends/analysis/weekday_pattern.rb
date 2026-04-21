# frozen_string_literal: true

# TASK-039 FR-027: Day-of-week TI/ERV/CCV pattern discovery.
# Output: 7-entry hash keyed by weekday symbol (:mon..:sun), each with
# {ti_avg, erv_avg_percent, streams_count}. Null entry for days без data.
#
# Source: trends_daily_aggregates (already date-indexed, partitioned).
# Uses EXTRACT(DOW FROM date) — PG mapping 0=Sun..6=Sat (remapped below).
#
# Insufficient_data guard: min days threshold via SignalConfiguration
# (trends/patterns/weekday_pattern_min_days, default 14). Below → returns
# :insufficient_data=true with full key set but nil metrics (API transparency).

module Trends
  module Analysis
    class WeekdayPattern
      WEEKDAYS = %i[sun mon tue wed thu fri sat].freeze # PG DOW 0..6

      def self.call(channel:, from:, to:)
        new(channel: channel, from: from, to: to).call
      end

      def initialize(channel:, from:, to:)
        @channel = channel
        @from = from
        @to = to
      end

      def call
        min_days = SignalConfiguration.value_for("trends", "patterns", "weekday_pattern_min_days").to_i
        total_days = aggregate_scope.distinct.count(:date)

        return { insufficient_data: true, weekday_patterns: empty_patterns, min_days_required: min_days } if total_days < min_days

        rows = aggregate_scope
          .group(Arel.sql("EXTRACT(DOW FROM date)"))
          .pluck(
            Arel.sql("EXTRACT(DOW FROM date)"),
            Arel.sql("AVG(ti_avg)"),
            Arel.sql("AVG(erv_avg_percent)"),
            Arel.sql("SUM(streams_count)")
          )

        by_dow = rows.to_h { |dow, ti, erv, cnt| [ dow.to_i, [ ti, erv, cnt ] ] }

        patterns = WEEKDAYS.each_with_index.to_h do |key, idx|
          ti, erv, cnt = by_dow[idx]
          [
            key,
            {
              ti_avg: ti&.to_f&.round(2),
              erv_avg_percent: erv&.to_f&.round(2),
              streams_count: cnt.to_i
            }
          ]
        end

        {
          insufficient_data: false,
          weekday_patterns: patterns,
          total_days: total_days
        }
      end

      private

      def aggregate_scope
        TrendsDailyAggregate
          .where(channel_id: @channel.id, date: @from..@to)
          .where.not(ti_avg: nil)
      end

      def empty_patterns
        WEEKDAYS.to_h { |k| [ k, { ti_avg: nil, erv_avg_percent: nil, streams_count: 0 } ] }
      end
    end
  end
end
