# frozen_string_literal: true

# TASK-039 Phase C1: Base class для Trends endpoint orchestrators.
# Parses + validates period/granularity, exposes resolve_range для analysis services.
#
# Valid periods per SRS §4.1: 7d / 30d / 60d / 90d / 365d.
# Granularity: daily (default) / per_stream / weekly (for 365d+).

module Trends
  module Api
    class BaseEndpointService
      class InvalidPeriod < StandardError; end
      class InvalidGranularity < StandardError; end
      class InsufficientData < StandardError; end

      VALID_PERIODS = %w[7d 30d 60d 90d 365d].freeze
      VALID_GRANULARITIES = %w[daily per_stream weekly].freeze
      DEFAULT_PERIOD = "30d"

      def initialize(channel:, period:, granularity: nil)
        @channel = channel
        @period = period.presence || DEFAULT_PERIOD
        @granularity = granularity.presence || "daily"

        raise InvalidPeriod, "Unknown period '#{@period}'" unless VALID_PERIODS.include?(@period)
        raise InvalidGranularity, "Unknown granularity '#{@granularity}'" unless VALID_GRANULARITIES.include?(@granularity)
      end

      protected

      attr_reader :channel, :period, :granularity

      def period_days
        case @period
        when "7d" then 7
        when "30d" then 30
        when "60d" then 60
        when "90d" then 90
        when "365d" then 365
        end
      end

      # Returns [from, to] as DateTime pair for SQL range scanning.
      # `to` = end-of-today to включить any stream сегодня.
      def range
        to = Time.current
        from = to - period_days.days
        [ from, to ]
      end

      # Returns Array of dates (inclusive) для serializers которые нужны per-day iteration.
      def date_range
        from, to = range
        (from.to_date..to.to_date)
      end

      # Shared meta block per SRS §4.1 (access_level, data_freshness).
      def meta
        {
          access_level: access_level_for_current_user,
          data_freshness: data_freshness
        }
      end

      def access_level_for_current_user
        # Simplified: Trends endpoint authorized → premium or streamer (both = premium access).
        # Future: expose tier label из ChannelPolicy for UI разграничения "premium" vs "business".
        "premium"
      end

      def data_freshness
        # Latest TDA update time vs now. "fresh" < 24h, "stale" otherwise.
        latest = TrendsDailyAggregate.where(channel_id: @channel.id).maximum(:updated_at)
        return "fresh" if latest.nil? # empty state — no drift to report

        (Time.current - latest) < 24.hours ? "fresh" : "stale"
      end
    end
  end
end
