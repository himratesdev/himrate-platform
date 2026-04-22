# frozen_string_literal: true

# TASK-039 FR-001: GET /api/v1/channels/:id/trends/erv endpoint orchestrator.
# Assembles M1 ERV Timeline response: points + trend + forecast + explanation + best/worst stream.
#
# Response shape per SRS §4.1. All analysis services из Phase B3.
# Granularity:
#   - daily (default): points from trends_daily_aggregates (aggregated per-day)
#   - per_stream: points from trust_index_histories (each stream one point)
#   - weekly: grouped weekly averages (for long periods 90d+)

module Trends
  module Api
    class ErvEndpointService < BaseEndpointService
      # CR N-1: threshold из SignalConfiguration через base#min_points_for_trend.
      # No magic number.

      def call
        points = build_points
        from_ts, to_ts = range

        summary = build_summary(points)
        trend = compute_trend(points)
        forecast = compute_forecast(points)
        explanation = build_explanation(trend)
        best_worst = fetch_best_worst(from_ts, to_ts)

        {
          data: {
            channel_id: channel.id,
            period: period,
            granularity: granularity,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            points: points,
            summary: summary,
            trend: trend,
            forecast: forecast,
            trend_explanation: explanation,
            best_stream: best_worst[:best],
            worst_stream: best_worst[:worst]
          },
          meta: meta
        }
      end

      private

      def build_points
        case granularity
        when "daily" then daily_points
        when "per_stream" then per_stream_points
        when "weekly" then weekly_points
        end
      end

      def daily_points
        from_ts, to_ts = range
        TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where.not(erv_avg_percent: nil)
          .order(:date)
          .pluck(:date, :erv_avg_percent, :erv_min_percent, :erv_max_percent, :ccv_avg)
          .map { |date, avg, min, max, ccv| point_for(date, avg, min, max, ccv) }
      end

      def per_stream_points
        from_ts, to_ts = range
        TrustIndexHistory
          .for_channel(channel.id)
          .where(calculated_at: from_ts..to_ts)
          .where.not(erv_percent: nil)
          .order(:calculated_at)
          .pluck(:calculated_at, :erv_percent, :ccv, :stream_id)
          .map do |ts, erv, ccv, stream_id|
            {
              date: ts.iso8601,
              erv_percent: erv.to_f.round(2),
              erv_absolute: erv_absolute(erv, ccv),
              ccv: ccv.to_i,
              stream_id: stream_id
            }
          end
      end

      def weekly_points
        from_ts, to_ts = range
        TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where.not(erv_avg_percent: nil)
          .group(Arel.sql("DATE_TRUNC('week', date)"))
          .pluck(
            Arel.sql("DATE_TRUNC('week', date) AS week"),
            Arel.sql("AVG(erv_avg_percent)"),
            Arel.sql("MIN(erv_min_percent)"),
            Arel.sql("MAX(erv_max_percent)"),
            Arel.sql("AVG(ccv_avg)")
          )
          .sort_by(&:first)
          .map { |week, avg, min, max, ccv| point_for(week.to_date, avg, min, max, ccv) }
      end

      def point_for(date, avg, min, max, ccv)
        {
          date: date.to_s,
          erv_percent: avg&.to_f&.round(2),
          erv_min_percent: min&.to_f&.round(2),
          erv_max_percent: max&.to_f&.round(2),
          erv_absolute: erv_absolute(avg, ccv),
          ccv_avg: ccv&.to_i,
          color: erv_color(avg)
        }
      end

      def erv_absolute(erv, ccv)
        return nil if erv.nil? || ccv.nil? || ccv.to_i.zero?

        (ccv.to_i * erv.to_f / 100.0).round
      end

      def erv_color(erv)
        return nil if erv.nil?
        return "green" if erv >= 80
        return "yellow" if erv >= 50

        "red"
      end

      def build_summary(points)
        return nil if points.empty?

        values = points.filter_map { |p| p[:erv_percent] }
        return nil if values.empty?

        {
          current: values.last,
          average: (values.sum / values.size).round(2),
          min: values.min,
          max: values.max,
          point_count: points.size
        }
      end

      def compute_trend(points)
        return empty_trend(n_points: points.size) if points.size < min_points_for_trend

        series = points.each_with_index.map { |p, i| [ i.to_f, p[:erv_percent] ] }
        Trends::Analysis::TrendCalculator.call(series)
      end

      def compute_forecast(points)
        return nil if points.size < min_points_for_forecast

        series = points.each_with_index.map { |p, i| [ i.to_f, p[:erv_percent] ] }
        Trends::Analysis::ForecastService.call(series)
      end

      def build_explanation(trend)
        Trends::Analysis::ExplanationBuilder.call(
          trend: trend, improvement_signals: [], degradation_signals: [], metric: metric_label
        )
      end

      def metric_label
        I18n.t("trends.metric.erv", default: "ERV%")
      end

      def fetch_best_worst(from_ts, to_ts)
        Trends::Analysis::BestWorstStreamFinder.call(
          channel_id: channel.id,
          from: from_ts,
          to: to_ts
        )
      end
    end
  end
end
