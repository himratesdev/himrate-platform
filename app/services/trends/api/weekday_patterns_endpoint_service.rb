# frozen_string_literal: true

# TASK-039 FR-009 (NEW v2.0): GET /api/v1/channels/:id/trends/patterns/weekday — M13.
# Thin wrapper над Trends::Analysis::WeekdayPattern (B3 service).
# Response per SRS §4.2: weekday_patterns {mon..sun: {ti_avg, erv_avg_percent, streams_count}}
# + insight_ru/en best-day narrative.

module Trends
  module Api
    class WeekdayPatternsEndpointService < BaseEndpointService
      # CR N-1: weekday labels (RU accusative case) moved в locale files (trends.{en,ru}.yml).

      def call
        from_ts, to_ts = range
        result = Trends::Analysis::WeekdayPattern.call(
          channel: channel, from: from_ts.to_date, to: to_ts.to_date
        )

        {
          data: {
            channel_id: channel.id,
            period: period,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            **result,
            insight_ru: build_insight(result, :ru),
            insight_en: build_insight(result, :en)
          },
          meta: meta
        }
      end

      private

      def build_insight(result, locale)
        return nil if result[:insufficient_data]

        patterns = result[:weekday_patterns]
        best = patterns.select { |_, v| v[:ti_avg] }.max_by { |_, v| v[:ti_avg] }
        return nil if best.nil?

        day_label = I18n.t("trends.weekday.accusative.#{best[0]}", locale: locale, default: best[0].to_s)
        ti = best[1][:ti_avg]

        I18n.t("trends.weekday.insight", locale: locale, day: day_label, ti: ti)
      end
    end
  end
end
