# frozen_string_literal: true

module Brand
  # Shared 30-day real-audience window over TrendsDailyAggregate (daily rollups). Single source for
  # both the Brand Streamer Card (#348 layer1 + top-level window) and Brand Compare (#23 per-channel
  # column) — so "real viewers" can never diverge between the two surfaces (no-drift). Real audience
  # is derived from ccv_avg × erv% (botted_fraction is NULL in production per DSV). Compute-on-read,
  # bounded to <= `days` daily rows per channel.
  class AudienceWindow
    DEFAULT_DAYS = 30
    BASIS = "trends_daily_aggregate_30d"

    def initialize(channel, days: DEFAULT_DAYS)
      @channel = channel
      @days = days
    end

    def rows
      @rows ||= TrendsDailyAggregate.where(channel_id: @channel.id, date: from..to).to_a
    end

    # Window metadata — defined even for a cold-start channel (0 streams in the window).
    def window_meta
      {
        days: @days,
        streams_count: rows.sum { |r| r.streams_count.to_i },
        days_covered: rows.count { |r| r.streams_count.to_i.positive? },
        from: from.iso8601,
        to: to.iso8601
      }
    end

    # Derived real-audience block, or {available:false} when the window has no usable data
    # (never zero-as-data).
    def audience
      return unavailable if rows.empty?

      ccv_avgs = rows.filter_map(&:ccv_avg)
      reals = rows.filter_map { |r| r.ccv_avg && r.erv_avg_percent ? r.ccv_avg * r.erv_avg_percent.to_f / 100 : nil }
      return unavailable if ccv_avgs.empty? || reals.empty?

      shown_avg = ccv_avgs.sum.to_f / ccv_avgs.size
      real_avg = reals.sum / reals.size
      return unavailable if shown_avg.zero?

      real_pct = (real_avg / shown_avg * 100).round(1)
      peak_reals = rows.filter_map { |r| r.ccv_peak && r.erv_avg_percent ? (r.ccv_peak * r.erv_avg_percent.to_f / 100).round : nil }
      {
        available: true,
        real_avg_viewers: real_avg.round,
        shown_avg_viewers: shown_avg.round,
        real_pct: real_pct,
        bot_correction_pct: (real_pct - 100).round(1),
        filtered_est: (shown_avg - real_avg).round,
        peak_real: peak_reals.max,
        peak_shown: rows.filter_map(&:ccv_peak).max,
        ti_avg: avg(rows.filter_map(&:ti_avg)),
        ti_std: avg(rows.filter_map(&:ti_std)),
        erv_pct_range: { min: rows.filter_map(&:erv_min_percent).min, max: rows.filter_map(&:erv_max_percent).max },
        basis: BASIS
      }
    end

    # Streams per week over the window (nil when the window is empty).
    def streams_per_week
      total = rows.sum { |r| r.streams_count.to_i }
      return nil if rows.empty?

      (total / (@days / 7.0)).round(1)
    end

    def from
      @from ||= @days.days.ago.to_date
    end

    def to
      @to ||= Date.current
    end

    private

    def unavailable
      { available: false, reason: "insufficient_window" }
    end

    def avg(values)
      return nil if values.empty?

      (values.sum.to_f / values.size).round(1)
    end
  end
end
