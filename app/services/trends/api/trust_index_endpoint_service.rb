# frozen_string_literal: true

# TASK-039 FR-002: GET /api/v1/channels/:id/trends/trust-index — M2 TI Timeline.
# Response per SRS §4.1 extended shape.

module Trends
  module Api
    class TrustIndexEndpointService < BaseEndpointService
      def call
        points = build_points
        from_ts, to_ts = range
        # CR S-4: compute trend ONCE, pass explicitly в build_explanation — memoization
        # pattern с `return inside begin` ненадёжен. Local var — clean + explicit.
        trend = compute_trend(points)

        {
          data: {
            channel_id: channel.id,
            period: period,
            granularity: granularity,
            from: from_ts.iso8601,
            to: to_ts.iso8601,
            points: points,
            summary: build_summary(points),
            trend: trend,
            forecast: compute_forecast(points),
            trend_explanation: build_explanation(trend),
            tier_changes: Trends::Analysis::TierChangeCounter.call(channel: channel, from: from_ts, to: to_ts),
            anomaly_markers: build_anomaly_markers(from_ts, to_ts)
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
          .where.not(ti_avg: nil)
          .order(:date)
          .pluck(:date, :ti_avg, :ti_std, :ti_min, :ti_max, :classification_at_end)
          .map { |date, avg, std, min, max, cls| point_for(date, avg, std, min, max, cls) }
      end

      def per_stream_points
        from_ts, to_ts = range
        TrustIndexHistory
          .for_channel(channel.id)
          .where(calculated_at: from_ts..to_ts)
          .where.not(trust_index_score: nil)
          .order(:calculated_at)
          .pluck(:calculated_at, :trust_index_score, :classification, :stream_id, :confidence)
          .map do |ts, ti, cls, stream_id, confidence|
            {
              date: ts.iso8601, ti: ti.to_f.round(2),
              classification: cls, stream_id: stream_id, confidence: confidence&.to_f&.round(3)
            }
          end
      end

      def weekly_points
        from_ts, to_ts = range
        TrendsDailyAggregate
          .where(channel_id: channel.id, date: from_ts.to_date..to_ts.to_date)
          .where.not(ti_avg: nil)
          .group(Arel.sql("DATE_TRUNC('week', date)"))
          .pluck(
            Arel.sql("DATE_TRUNC('week', date) AS week"),
            Arel.sql("AVG(ti_avg)"),
            Arel.sql("AVG(ti_std)"),
            Arel.sql("MIN(ti_min)"),
            Arel.sql("MAX(ti_max)")
          )
          .sort_by(&:first)
          .map { |week, avg, std, min, max| point_for(week.to_date, avg, std, min, max, nil) }
      end

      def point_for(date, avg, std, min, max, cls)
        {
          date: date.to_s,
          ti: avg&.to_f&.round(2),
          ti_std: std&.to_f&.round(2),
          ti_min: min&.to_f&.round(2),
          ti_max: max&.to_f&.round(2),
          classification: cls
        }
      end

      def build_summary(points)
        return nil if points.empty?

        values = points.filter_map { |p| p[:ti] }
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

        series = points.each_with_index.map { |p, i| [ i.to_f, p[:ti] ] }
        Trends::Analysis::TrendCalculator.call(series)
      end

      def compute_forecast(points)
        return nil if points.size < min_points_for_forecast

        series = points.each_with_index.map { |p, i| [ i.to_f, p[:ti] ] }
        Trends::Analysis::ForecastService.call(series)
      end

      def build_explanation(trend)
        Trends::Analysis::ExplanationBuilder.call(
          trend: trend, improvement_signals: [], degradation_signals: [], metric: metric_label
        )
      end

      def metric_label
        I18n.t("trends.metric.trust_index", default: "Trust Index")
      end

      def build_anomaly_markers(from_ts, to_ts)
        Anomaly
          .joins(:stream)
          .where(streams: { channel_id: channel.id })
          .where(timestamp: from_ts..to_ts)
          .order(:timestamp)
          .pluck(:id, :timestamp, :anomaly_type, :confidence)
          .map do |id, ts, type, conf|
            {
              anomaly_id: id,
              date: ts.iso8601,
              type: type,
              confidence: conf&.to_f&.round(3)
            }
          end
      end
    end
  end
end
