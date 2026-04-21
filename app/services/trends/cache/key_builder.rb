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
      # Stored в Redis напрямую (не Rails.cache) чтобы выдерживать cache clear без
      # потери invalidation counter.
      def current_epoch
        store = ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
        (store.get(epoch_key) || 0).to_i
      ensure
        store&.close
      end

      def epoch_key
        "#{EPOCH_NAMESPACE}:#{@channel_id}"
      end

      # Invalidation TTL per period (SRS §9, FR-035).
      # race_condition_ttl (SRS FR-037) — separate Rails.cache.fetch option.
      def self.ttl_for(period)
        case period.to_s
        when "7d", "30d" then 30.minutes
        when "60d", "90d" then 2.hours
        when "365d" then 24.hours
        else 30.minutes
        end
      end

      # race_condition_ttl per period (SRS §9 table):
      # 30s для short periods, 60s для long (more expensive compute = longer lock).
      def self.race_condition_ttl_for(period)
        case period.to_s
        when "365d" then 60.seconds
        else 30.seconds
        end
      end
    end
  end
end
