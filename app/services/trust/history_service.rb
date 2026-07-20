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

      # TI histories for the same period (PR3b: engine-aware — v2 plucks the native contract)
      ti_points = if v2_engine?
        TrustIndexHistory
          .where(channel_id: @channel.id, engine_version: "v2")
          .where("calculated_at > ?", cutoff)
          .order(:calculated_at)
          .pluck(:calculated_at, :erv, :authenticity, :band_color)
      else
        TrustIndexHistory
          .where(channel_id: @channel.id, engine_version: "v1")
          .where("calculated_at > ?", cutoff)
          .order(:calculated_at)
          .pluck(:calculated_at, :trust_index_score, :erv_percent)
      end

      # Merge by nearest timestamp (CCV as base, TI interpolated)
      v2_engine? ? merge_timeseries_v2(ccv_points, ti_points) : merge_timeseries(ccv_points, ti_points)
    end

    # 7d: daily aggregates (last record per day)
    # PR3b: v2 branch aggregates authenticity (%, scale-safe across days) — averaging raw erv
    # COUNTS across days with different V baselines is meaningless; erv arrives per-point in 30m.
    def points_7d
      cutoff = 7.days.ago

      return points_7d_v2(cutoff) if v2_engine?

      TrustIndexHistory
        .where(channel_id: @channel.id, engine_version: "v1")
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

    # TASK-085 FR-023: fix broken Anomaly query (channel_id/detected_at/severity/delta_value
    # columns не существуют в actual Anomaly schema — pre-fix wrapped в silent rescue, dead code).
    # Correct mapping: Anomaly belongs_to :stream, stream belongs_to :channel.
    # Filter via JOIN; timestamp column instead of detected_at; expose details jsonb instead of severity.
    def build_anomalies
      cutoff = @period == "30m" ? 30.minutes.ago : 7.days.ago

      Anomaly
        .joins(stream: :channel)
        .where(channels: { id: @channel.id })
        .where("anomalies.timestamp > ?", cutoff)
        .order(timestamp: :desc)
        .limit(20)
        .map do |a|
          {
            timestamp: a.timestamp.iso8601,
            type: a.anomaly_type,
            confidence: a.confidence&.to_f,
            details: a.details
          }
        end
    end

    def points_7d_v2(cutoff)
      TrustIndexHistory
        .where(channel_id: @channel.id, engine_version: "v2")
        .where("calculated_at > ?", cutoff)
        .select(
          "DATE(calculated_at) as day",
          "AVG(authenticity) as avg_auth",
          "MAX(ccv) as max_ccv",
          "COUNT(*) as sample_count"
        )
        .group("DATE(calculated_at)")
        .order("day")
        .map do |row|
          {
            timestamp: row.day.to_s,
            ccv: row.max_ccv&.to_i,
            erv: nil, # daily aggregate — counts are V-scale-dependent, no single value
            authenticity: row.avg_auth&.to_f&.round(1)
          }
        end
    end

    # v2 point shape: {timestamp, ccv, erv (native count), authenticity, band_color} — the
    # ccv×ti/100 derivation is retired (erv is the engine's subtracted count).
    def merge_timeseries_v2(ccv_points, ti_points)
      return [] if ccv_points.empty?

      ti_index = 0
      ccv_points.map do |ts, ccv|
        while ti_index < ti_points.size - 1 &&
              ti_points[ti_index + 1][0] <= ts
          ti_index += 1
        end

        ti_row = ti_points[ti_index]
        {
          timestamp: ts.iso8601,
          ccv: ccv&.to_i,
          erv: ti_row&.[](1),
          authenticity: ti_row&.[](2)&.to_f&.round(1),
          band_color: ti_row&.[](3)
        }
      end
    end

    def v2_engine?
      return @v2_engine if defined?(@v2_engine)

      @v2_engine =
        begin
          Flipper.enabled?(:ti_v2_engine)
        rescue StandardError
          false
        end
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
