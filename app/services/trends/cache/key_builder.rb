# frozen_string_literal: true

# TASK-039 FR-035 + ADR §4.12: Versioned cache key builder для Trends API.
# Формат: trends:{channel_id}:{endpoint}:{period}:{granularity}:v{schema_version}:{invalidation_epoch}
#
# schema_version — из SignalConfiguration trends/cache/schema_version (build-for-years:
# admin bumps когда breaking change в response shape, instantly invalidates все cached responses).
#
# invalidation_epoch — per-channel counter в Redis (incremented по PostStreamWorker).
# Позволяет O(1) invalidation для одного канала — не надо сканировать keys.

module Trends
  module Cache
    class KeyBuilder
      EPOCH_NAMESPACE = "trends:epoch"

      def self.call(channel_id:, endpoint:, period:, granularity: "daily")
        new(channel_id: channel_id, endpoint: endpoint, period: period, granularity: granularity).call
      end

      def initialize(channel_id:, endpoint:, period:, granularity:)
        @channel_id = channel_id
        @endpoint = endpoint
        @period = period
        @granularity = granularity
      end

      def call
        schema_version = SignalConfiguration.value_for("trends", "cache", "schema_version").to_i
        epoch = current_epoch

        "trends:#{@channel_id}:#{@endpoint}:#{@period}:#{@granularity}:v#{schema_version}:e#{epoch}"
      end

      # Current invalidation epoch for channel (0 if never invalidated).
      # Stored в Redis напрямую (не Rails.cache) чтобы выдерживать Rails.cache clear
      # без потери invalidation counter (epoch = durable, Rails.cache body = ephemeral).
      #
      # CR M-1: pooled connection через Trends::RedisPool. Zero TCP churn per request
      # (100k+ каналов scale). Pool timeout 5s — graceful под Redis latency spikes.
      def current_epoch
        Trends::RedisPool.with do |redis|
          (redis.get(epoch_key) || 0).to_i
        end
      end

      def epoch_key
        "#{EPOCH_NAMESPACE}:#{@channel_id}"
      end

      # Per-endpoint TTL override table per SRS §9 explicit values (CR S-1).
      # Endpoints с fixed TTL regardless of period (compute cost не зависит от окна).
      # Default (не в таблице) = period-based (30m/2h/24h).
      ENDPOINT_TTL_OVERRIDES = {
        "categories" => 6.hours,          # SRS §9: 6h all periods
        "weekday_patterns" => 6.hours,    # SRS §9: 6h all periods
        "insights" => 1.hour,              # SRS §9: 1h (expensive orchestration)
        "rehabilitation" => 10.minutes     # SRS §9: 10m (fresh rehab scoreboard)
      }.freeze

      # Invalidation TTL per endpoint × period (SRS §9, FR-035).
      # Endpoint-specific override takes precedence; fallback = period-based tier.
      def self.ttl_for(period, endpoint: nil)
        return ENDPOINT_TTL_OVERRIDES[endpoint.to_s] if endpoint && ENDPOINT_TTL_OVERRIDES.key?(endpoint.to_s)

        case period.to_s
        when "7d", "30d" then 30.minutes
        when "60d", "90d" then 2.hours
        when "365d" then 24.hours
        else 30.minutes
        end
      end

      # race_condition_ttl per endpoint × period (SRS §9):
      # endpoint-specific expensive paths (insights, comparison) = 60s lock.
      # Default period-based: 30s short, 60s 365d.
      EXPENSIVE_ENDPOINTS = %w[insights comparison categories weekday_patterns].freeze

      def self.race_condition_ttl_for(period, endpoint: nil)
        return 60.seconds if endpoint && EXPENSIVE_ENDPOINTS.include?(endpoint.to_s)
        return 60.seconds if period.to_s == "365d"

        30.seconds
      end
    end
  end
end
