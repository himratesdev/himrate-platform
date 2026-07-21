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
            trend_explanation: explanation
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
        # PR3b: COALESCE — v2 days carry authenticity_avg (the "% real" heir) + erv_avg_count
        TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where("erv_avg_percent IS NOT NULL OR authenticity_avg IS NOT NULL")
          .order(:date)
          .pluck(:date,
                 Arel.sql("COALESCE(erv_avg_percent, authenticity_avg)"),
                 Arel.sql("COALESCE(erv_min_percent, authenticity_min)"),
                 Arel.sql("COALESCE(erv_max_percent, authenticity_max)"),
                 :ccv_avg, :erv_avg_count, :band_color_at_end)
          .map { |date, avg, min, max, ccv, cnt, bcolor| point_for(date, avg, min, max, ccv, erv_count: cnt, band_color: bcolor) }
      end

      # PR3b: per-row engine discrimination. v2 rows emit the NATIVE count (erv) + interval +
      # engine band color; erv_percent for v2 = authenticity (same "% real" meaning). The 3-color
      # reader-side erv_color fn only ever sees v1 rows.
      def per_stream_points
        from_ts, to_ts = range
        TrustIndexHistory
          .for_channel(channel.id)
          .where(calculated_at: from_ts..to_ts)
          .where("(engine_version = 'v1' AND erv_percent IS NOT NULL) OR (engine_version = 'v2' AND erv IS NOT NULL)")
          .order(:calculated_at)
          .pluck(:calculated_at, :erv_percent, :ccv, :stream_id, :engine_version, :erv, :erv_lo, :erv_hi, :authenticity, :band_color)
          .map do |ts, erv_pct, ccv, stream_id, engine, erv, erv_lo, erv_hi, auth, band_color|
            if engine == "v2"
              {
                date: ts.iso8601,
                erv: erv,
                erv_interval: { lo: erv_lo, hi: erv_hi },
                erv_percent: auth&.to_f&.round(2),
                erv_absolute: erv,
                ccv: ccv.to_i,
                stream_id: stream_id,
                color: band_color,
                engine_version: "v2"
              }
            else
              {
                date: ts.iso8601,
                erv_percent: erv_pct.to_f.round(2),
                erv_absolute: erv_absolute(erv_pct, ccv),
                ccv: ccv.to_i,
                stream_id: stream_id,
                engine_version: "v1"
              }
            end
          end
      end

      def weekly_points
        from_ts, to_ts = range
        TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where("erv_avg_percent IS NOT NULL OR authenticity_avg IS NOT NULL")
          .group(Arel.sql("DATE_TRUNC('week', date)"))
          .pluck(
            Arel.sql("DATE_TRUNC('week', date) AS week"),
            Arel.sql("AVG(COALESCE(erv_avg_percent, authenticity_avg))"),
            Arel.sql("MIN(COALESCE(erv_min_percent, authenticity_min))"),
            Arel.sql("MAX(COALESCE(erv_max_percent, authenticity_max))"),
            Arel.sql("AVG(ccv_avg)"),
            Arel.sql("AVG(erv_avg_count)")
          )
          .sort_by(&:first)
          .map { |week, avg, min, max, ccv, cnt| point_for(week.to_date, avg, min, max, ccv, erv_count: cnt) }
      end

      def point_for(date, avg, min, max, ccv, erv_count: nil, band_color: nil)
        {
          date: date.to_s,
          erv_percent: avg&.to_f&.round(2),
          erv_min_percent: min&.to_f&.round(2),
          erv_max_percent: max&.to_f&.round(2),
          # v2 days: native count; v1 days: ccv×% derivation
          erv_absolute: erv_count ? erv_count.to_f.round : erv_absolute(avg, ccv),
          ccv_avg: ccv&.to_i,
          # engine band color when persisted (5 values incl. amber/grey); 3-color threshold fn = v1-only
          color: band_color || erv_color(avg)
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
        # T1-074 surface-audit: key resolved per-locale inside the builder; the old
        # default: "ERV%" fallback leaked retired rescale-percent vocabulary (key was missing).
        Trends::Analysis::ExplanationBuilder.call(
          trend: trend, improvement_signals: [], degradation_signals: [], metric_key: "trends.metric.erv"
        )
      end
    end
  end
end
