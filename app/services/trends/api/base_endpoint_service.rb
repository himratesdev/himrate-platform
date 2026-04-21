# frozen_string_literal: true

# TASK-039 Phase C1: Base class для Trends endpoint orchestrators.
# Parses + validates period/granularity, exposes range + meta + shared helpers.
#
# Valid periods per SRS §4.1: 7d / 30d / 60d / 90d / 365d.
# Granularity: daily (default) / per_stream / weekly (for 365d+).
#
# CR S-3: accepts user: для accurate access_level resolution через ChannelPolicy
# (business / premium / streamer / free). Не hardcoded.
# CR N-2: empty_trend helper shared across TI + ERV subclasses.

module Trends
  module Api
    class BaseEndpointService
      class InvalidPeriod < StandardError; end
      class InvalidGranularity < StandardError; end
      class InsufficientData < StandardError; end

      VALID_PERIODS = %w[7d 30d 60d 90d 365d].freeze
      VALID_GRANULARITIES = %w[daily per_stream weekly].freeze
      DEFAULT_PERIOD = "30d"

      def initialize(channel:, period:, granularity: nil, user: nil)
        @channel = channel
        @user = user
        @period = period.presence || DEFAULT_PERIOD
        @granularity = granularity.presence || "daily"

        raise InvalidPeriod, "Unknown period '#{@period}'" unless VALID_PERIODS.include?(@period)
        raise InvalidGranularity, "Unknown granularity '#{@granularity}'" unless VALID_GRANULARITIES.include?(@granularity)
      end

      protected

      attr_reader :channel, :period, :granularity, :user

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
      def range
        to = Time.current
        from = to - period_days.days
        [ from, to ]
      end

      def date_range
        from, to = range
        (from.to_date..to.to_date)
      end

      # CR N-2: shared shape for empty trend (insufficient data case). ErvEndpointService +
      # TrustIndexEndpointService dedupe через этот helper.
      def empty_trend(n_points: 0)
        {
          direction: nil, slope_per_day: nil, delta: nil,
          r_squared: nil, confidence: nil, start_value: nil, end_value: nil, n_points: n_points
        }
      end

      # CR N-1: минимум points для trend compute читается из SignalConfiguration.
      # Консистентно с TrendCalculator внутренней логикой (которая возвращает nil-shape
      # при <2 points) — external guard здесь для fast-path skip (экономит LinearRegression call).
      def min_points_for_trend
        SignalConfiguration.value_for("trends", "trend", "confidence_medium_r2") # triggers cache warm
        # Minimum 3 points для naively-fit линии + R². Хранится отдельно чтобы admin мог tune.
        SignalConfiguration.value_for("trends", "trend", "min_points_for_trend").to_i
      rescue SignalConfiguration::ConfigurationMissing
        3 # fallback до следующего seed migration (graceful degradation).
      end

      def min_points_for_forecast
        SignalConfiguration.value_for("trends", "forecast", "min_points_for_forecast").to_i
      rescue SignalConfiguration::ConfigurationMissing
        14
      end

      # Shared meta block per SRS §4.1 (access_level, data_freshness).
      def meta
        {
          access_level: resolve_access_level,
          data_freshness: data_freshness
        }
      end

      # CR S-3: resolve access_level через ChannelPolicy (не hardcoded "premium").
      # "business" | "premium" | "streamer" | "free" — UI использует для корректного CTA.
      def resolve_access_level
        return "anonymous" if @user.nil?

        policy = ChannelPolicy.new(@user, @channel)
        return "business" if policy.effective_business_access?
        return "streamer" if policy.owns_channel_access?
        return "premium" if policy.premium_access?

        "free"
      end

      def data_freshness
        latest = TrendsDailyAggregate.where(channel_id: @channel.id).maximum(:updated_at)
        return "fresh" if latest.nil?

        (Time.current - latest) < 24.hours ? "fresh" : "stale"
      end
    end
  end
end
