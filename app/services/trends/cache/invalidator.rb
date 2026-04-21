# frozen_string_literal: true

# TASK-039 FR-036: Cache invalidation hook для Trends API.
# Принцип: bump per-channel invalidation epoch → все existing cached responses
# этого канала становятся stale (KeyBuilder включает epoch в key).
#
# O(1) invalidation — INCR операция в Redis, не требует scan/delete по pattern.
# Вызывается из PostStreamWorker после stream end → следующий request = fresh compute.
#
# Graceful degradation: если Redis недоступен — invalidation silently fails, но
# cache сам инвалидируется по TTL в течение 30m-24h (SRS §9). Error reported via
# Rails.error.report для Sentry visibility.

module Trends
  module Cache
    class Invalidator
      def self.call(channel_id)
        new(channel_id).call
      end

      def initialize(channel_id)
        @channel_id = channel_id
      end

      def call
        store = ::Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
        key = Trends::Cache::KeyBuilder.new(
          channel_id: @channel_id, endpoint: "_", period: "_", granularity: "_"
        ).epoch_key

        new_epoch = store.incr(key)

        ActiveSupport::Notifications.instrument(
          "trends.cache.invalidated",
          channel_id: @channel_id,
          new_epoch: new_epoch
        )

        new_epoch
      rescue StandardError => e
        Rails.error.report(
          e,
          context: { service: "Trends::Cache::Invalidator", channel_id: @channel_id },
          handled: true
        )
        Rails.logger.warn("[Trends::Cache::Invalidator] channel=#{@channel_id} failed: #{e.class} #{e.message}")
        nil
      ensure
        store&.close
      end
    end
  end
end
