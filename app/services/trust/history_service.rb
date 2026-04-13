# frozen_string_literal: true

# TASK-035 FR-017: Sparkline data for Side Panel Overview.
# Returns time-series points for 30m (live) or 7d (offline) periods.
# FND-001: includes anomalies[] for future Anomalies Timeline (TASK-039).

module Trust
  class HistoryService
    VALID_PERIODS = %w[30m 7d].freeze

    def initialize(channel:, period:)
      @channel = channel
      @period = period
    end

    def call
      return { error: "invalid_period" } unless VALID_PERIODS.include?(@period)

      {
        period: @period,
        points: build_points,
        anomalies: build_anomalies
      }
    end

    private

    def build_points
      case @period
      when "30m" then points_30m
      when "7d" then points_7d
      end
    end

    # 30m: last 30 data points from current stream (1 per minute)
    def points_30m
      current_stream = @channel.streams.where(ended_at: nil).order(started_at: :desc).first
      return [] unless current_stream

      cutoff = 30.minutes.ago

      # CCV snapshots (taken ~every 60s by StreamMonitorWorker)
      ccv_points = CcvSnapshot
        .where(stream: current_stream)
        .where("timestamp > ?", cutoff)
        .order(:timestamp)
        .pluck(:timestamp, :ccv_count)

      # TI histories for the same period
      ti_points = TrustIndexHistory
        .where(channel_id: @channel.id)
        .where("calculated_at > ?", cutoff)
        .order(:calculated_at)
        .pluck(:calculated_at, :trust_index_score, :erv_percent)

      # Merge by nearest timestamp (CCV as base, TI interpolated)
      merge_timeseries(ccv_points, ti_points)
    end

    # 7d: daily aggregates (last record per day)
    def points_7d
      cutoff = 7.days.ago

      TrustIndexHistory
        .where(channel_id: @channel.id)
        .where("calculated_at > ?", cutoff)
        .select(
          "DATE(calculated_at) as day",
          "AVG(trust_index_score) as avg_ti",
          "AVG(erv_percent) as avg_erv",
          "MAX(ccv) as max_ccv",
          "COUNT(*) as sample_count"
        )
        .group("DATE(calculated_at)")
        .order("day")
        .map do |row|
          {
            timestamp: row.day.to_s,
            ccv: row.max_ccv&.to_i,
            erv_count: nil, # daily aggregate — no single erv_count
            erv_percent: row.avg_erv&.to_f&.round(1),
            ti_score: row.avg_ti&.to_f&.round(1)
          }
        end
    end

    # FND-001: anomalies from anomalies table for foundation
    def build_anomalies
      current_stream = @channel.streams.order(started_at: :desc).first
      return [] unless current_stream

      cutoff = @period == "30m" ? 30.minutes.ago : 7.days.ago

      Anomaly
        .where(channel_id: @channel.id)
        .where("detected_at > ?", cutoff)
        .order(detected_at: :desc)
        .limit(20)
        .map do |a|
          {
            timestamp: a.detected_at.iso8601,
            type: a.anomaly_type,
            severity: a.severity,
            delta: a.delta_value&.to_f
          }
        end
    rescue ActiveRecord::StatementInvalid
      # Anomaly table may not exist yet — graceful fallback
      []
    end

    def merge_timeseries(ccv_points, ti_points)
      return [] if ccv_points.empty?

      ti_index = 0
      ccv_points.map do |ts, ccv|
        # Find nearest TI point
        while ti_index < ti_points.size - 1 &&
              ti_points[ti_index + 1][0] <= ts
          ti_index += 1
        end

        ti_row = ti_points[ti_index]
        ti_score = ti_row&.[](1)&.to_f
        erv_percent = ti_row&.[](2)&.to_f
        erv_count = ti_score && ccv ? (ccv * ti_score / 100.0).round : nil

        {
          timestamp: ts.iso8601,
          ccv: ccv&.to_i,
          erv_count: erv_count,
          erv_percent: erv_percent&.round(1),
          ti_score: ti_score&.round(1)
        }
      end
    end
  end
end
