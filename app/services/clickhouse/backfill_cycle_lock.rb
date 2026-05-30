# frozen_string_literal: true

module Clickhouse
  # TASK-251.58: overlap-guard for the chat backfill cycle worker.
  #
  # Used by `Clickhouse::ChatBackfillCycleWorker` to prevent concurrent #tick invocations from
  # corrupting the cursor advance. The scenarios this guards against:
  #   - Multi-instance Sidekiq deploy (two job containers, both running the cron worker)
  #   - A single #tick run that overran MAX_RUNTIME_SECONDS (50s) past the next 60s cron tick,
  #     so the new tick fires before the old one returned
  #
  # CR iter4 dropped the rake-side blocking loop, so `Clickhouse::ChatBackfill#call` no longer
  # competes with the worker — the rake task is now a T0-seed-and-exit and never invokes #tick.
  # The lock module is kept as a separate file so it stays unit-testable in isolation.
  #
  # Without overlap guard, two concurrent #tick calls would both read the same Redis cursor,
  # both fetch the same PG batch, and both insert duplicate rows into the raw chat_messages CH
  # table (MergeTree, NO engine-level dedup — explicitly called out in `chat_backfill.rb` T0
  # safety-margin comment).
  #
  # Client-agnostic via the raw `c.call("SET", ...)` / `c.call("EVAL", ...)` form. Both the
  # redis-rb 5 client (used by `Clickhouse::ChatBackfill@redis` constructed via `Redis.new`)
  # and Sidekiq's `RedisClient::CompatClient` (yielded by `Sidekiq.redis`) accept the raw
  # protocol form. The CR iter2 finding (lock_release TypeError in prod) was specifically that
  # `c.eval(script, keys: [], argv: [])` works on redis-rb 5 but NOT on CompatClient — only
  # the raw `c.call("EVAL", script, numkeys, *keys, *argv)` form is safe for both.
  module BackfillCycleLock
    module_function

    KEY = "#{Clickhouse::ChatBackfill::REDIS_PREFIX}:cycle_lock"
    # TTL exceeds the longest expected hold (cron worker's MAX_RUNTIME_SECONDS) by enough margin
    # that a hung holder cannot starve the next acquirer past ~30s beyond the runtime budget.
    DEFAULT_TTL_SECONDS = 80

    # Atomic SETNX with TTL. Returns true on acquisition, false if another holder owns the key.
    # The caller is responsible for storing `token` and passing it to `release` so we never
    # delete a lock that has expired and been re-acquired by a different holder (Redlock idiom).
    def acquire(redis_client, token, ttl_seconds: DEFAULT_TTL_SECONDS)
      result = redis_client.call("SET", KEY, token, "NX", "EX", ttl_seconds)
      result == "OK"
    end

    # Atomic check-and-delete via Lua: only DEL if the value at KEY still matches our token.
    # Prevents the worker from releasing a lock that has already expired and been re-acquired
    # by a later holder.
    def release(redis_client, token)
      redis_client.call("EVAL", RELEASE_SCRIPT, 1, KEY, token)
    rescue StandardError => e
      # Best-effort: log + let the TTL handle cleanup. Re-raising would swallow the operator-
      # observable failure mode (the lock-held line on next acquire) behind a Sidekiq retry,
      # which is worse than a silent TTL expiration.
      Rails.logger.warn("Clickhouse::BackfillCycleLock: release failed (#{e.class}: #{e.message.truncate(120)}) — lock will expire via TTL (#{DEFAULT_TTL_SECONDS}s)")
      nil
    end

    RELEASE_SCRIPT = <<~LUA
      if redis.call('GET', KEYS[1]) == ARGV[1] then
        return redis.call('DEL', KEYS[1])
      else
        return 0
      end
    LUA
    private_constant :RELEASE_SCRIPT
  end
end
