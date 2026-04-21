# frozen_string_literal: true

# TASK-039 ADR §4.12: Cache versioning for Trends API responses.
# schema_version = 2 — matches trends_daily_aggregates.schema_version default +
# signal_configurations 'trends/cache/schema_version' seed (migration 100006).
#
# Bump этого значения при любом breaking change response shape (add/remove/rename fields
# в API или DB schema). Bump вместе с миграцией изменяющей schema_version default.
# Single source of truth для cache key format: trends:{channel_id}:{endpoint}:{period}:v{N}.

Rails.application.config.x.trends_cache_version = 2

# TASK-039 Phase C1 CR M-1: Dedicated Redis connection pool для cache metadata
# (invalidation epoch). Избегает ::Redis.new per request — file descriptor exhaustion
# + TCP handshake overhead при 100k+ каналов scale (SRS §1.2).
#
# Size = Sidekiq concurrency (default 10) + Puma max_threads (16) + buffer. Tunable
# via ENV TRENDS_REDIS_POOL_SIZE. Timeout — 5s aligns с http defaults (SRS §8.3 reliability).
#
# Usage:
#   Trends::RedisPool.with { |redis| redis.get(key) }
#
# Lives в /0 DB (app-level cache), отдельно от Sidekiq queues (/0 in sidekiq.yml → namespaced).
module Trends
  REDIS_POOL_SIZE = ENV.fetch("TRENDS_REDIS_POOL_SIZE", 25).to_i
  REDIS_POOL_TIMEOUT = ENV.fetch("TRENDS_REDIS_POOL_TIMEOUT", 5).to_i

  # CR PG W-1: fail-fast в production когда REDIS_URL не выставлен. Dev/test
  # fallback preserved для local docker-compose setup. Match pattern из routes.rb
  # (FLIPPER_UI_PASSWORD guard).
  RedisPool = ConnectionPool.new(size: REDIS_POOL_SIZE, timeout: REDIS_POOL_TIMEOUT) do
    url = ENV.fetch("REDIS_URL") do
      raise "REDIS_URL env var is required in production" if Rails.env.production?

      "redis://localhost:6379/0"
    end
    Redis.new(url: url)
  end
end
