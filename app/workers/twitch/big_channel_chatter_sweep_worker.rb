# frozen_string_literal: true

# BUG-251.31 G-3 PR-A2: opt-in parallel chatter sweep for big channels.
#
# Why a separate worker (not inline in `StreamMonitorWorker`):
# StreamMonitorWorker runs ~1/min over ALL active streams. Inlining
# `community_tab_parallel(20)` there would multiply Twitch GQL load 20× across
# the live-stream fleet (~21k req/min on 428 streams during peak) — instant
# 429. Instead, StreamMonitorWorker detects "big channel + cap hit" and
# **enqueues** this worker, which runs out-of-band with its own throttle.
#
# Cadence: throttled at one sweep per channel per `SWEEP_THROTTLE_TTL`
# (Redis SETNX, defaults to 5 minutes). Multiple StreamMonitorWorker cycles
# inside that window will SETNX-fail and noop — single-flight semantics
# (same pattern as `CrossChannelDigestRefreshWorker`).
#
# Operational gate: BigChannelChatterSweepWorker is wired but its execution is
# itself gated by the `:big_channel_chatter_sweep` Flipper flag (default OFF
# at boot). PR-A2 lands the wiring with the flag DISABLED — enable on staging
# after rake-probe measurement confirms the ~20-parallel baseline (validated
# 2026-06-03 on summit1g: 100 cap-hit → 1781 unique, dedupe_ratio 0.89, 602ms).
#
# Scope of this worker (PR-A2): purely observability + measurement on real
# live big channels (replay-the-rake-probe-but-async). Logs the dedupe ratio,
# unique-viewer count, single vs parallel coverage so we have a production
# dataset before PR-A3 wires the sweep result into ChattersSnapshot persistence.

module Twitch
  class BigChannelChatterSweepWorker
    include Sidekiq::Job
    # CR iter-1 M1: `:job` is a Kamal ROLE name, not a registered Sidekiq queue
    # (see config/sidekiq.yml :queues:) — enqueueing there would silently lose
    # jobs once the flag flips on. Sibling out-of-band Twitch-GQL probes
    # (CrossChannelDigestRefreshWorker, FollowerSnapshotWorker, ChatterProfileRefreshWorker,
    # StaleStreamSweepWorker, StreamMonitorWorker, ChannelDiscoveryWorker,
    # CleanupWorker) all use `:monitoring` — same class of work.
    sidekiq_options queue: :monitoring, retry: 2

    SWEEP_THROTTLE_KEY_PREFIX = "twitch:big_chatter_sweep:throttle:"
    SWEEP_THROTTLE_TTL = ENV.fetch("BIG_CHANNEL_CHATTER_SWEEP_TTL", "300").to_i  # 5 min default
    DEFAULT_CONCURRENT_CALLS = ENV.fetch("BIG_CHANNEL_CHATTER_SWEEP_PARALLEL", "20").to_i
    # CR iter-1 S2: wall-clock ceiling on the whole sweep. Each inner thread inherits
    # community_tab → execute's 5s timeout × 3 retries (≈20s worst-case per thread); the
    # threads run concurrently, so the bound for the whole sweep is the slowest thread,
    # not the sum. 30s gives ~50% headroom over that worst case and matches the staging
    # GQL response p99 envelope. Beyond this we explicitly fail the job (retry once via
    # Sidekiq's `retry: 2`) rather than tie up a `:monitoring` thread indefinitely.
    SWEEP_WALL_CEILING_SEC = ENV.fetch("BIG_CHANNEL_CHATTER_SWEEP_WALL_CEILING_SEC", "30").to_i

    class SweepTimeoutError < StandardError; end

    def perform(channel_id, concurrent_calls = DEFAULT_CONCURRENT_CALLS)
      return unless Flipper.enabled?(:big_channel_chatter_sweep)

      # CR iter-1 N1: respect Channel soft-delete contract (other callers in
      # the codebase use `.active`). For a channel that gets soft-deleted between
      # StreamMonitorWorker enqueue and worker execution, we'd otherwise still
      # fire 20 Twitch GQL calls to log observability we'll never use.
      channel = Channel.active.find_by(id: channel_id)
      return unless channel
      return if channel.login.blank?

      throttle_key = "#{SWEEP_THROTTLE_KEY_PREFIX}#{channel_id}"
      acquired = Sidekiq.redis { |c| c.set(throttle_key, "1", nx: true, ex: SWEEP_THROTTLE_TTL) }
      unless acquired
        Rails.logger.debug("[BigChannelChatterSweep] skip channel=#{channel.login} — throttled within #{SWEEP_THROTTLE_TTL}s")
        return
      end

      t0 = Time.current
      result =
        begin
          Timeout.timeout(SWEEP_WALL_CEILING_SEC, SweepTimeoutError) do
            Twitch::GqlClient.new.community_tab_parallel(
              channel_login: channel.login,
              concurrent_calls: concurrent_calls
            )
          end
        rescue SweepTimeoutError
          Rails.logger.warn("[BigChannelChatterSweep] channel=#{channel.login} exceeded #{SWEEP_WALL_CEILING_SEC}s wall ceiling — aborted")
          nil
        end
      elapsed_ms = ((Time.current - t0) * 1000).round

      if result.nil?
        Rails.logger.warn("[BigChannelChatterSweep] channel=#{channel.login} returned nil — all threads errored or hit wall ceiling")
        return
      end

      Rails.logger.info(
        "[BigChannelChatterSweep] channel=#{channel.login} parallel=#{result[:parallel_calls]} " \
        "successful=#{result[:successful_calls]} unique=#{result[:unique_viewer_logins]} " \
        "samples_total=#{result[:viewer_samples_total]} dedupe_ratio=#{result[:dedupe_ratio]} " \
        "count=#{result[:count]} elapsed_ms=#{elapsed_ms}"
      )

      ActiveSupport::Notifications.instrument(
        "twitch.big_channel_chatter_sweep",
        channel_id: channel_id,
        channel_login: channel.login,
        parallel_calls: result[:parallel_calls],
        successful_calls: result[:successful_calls],
        unique_viewer_logins: result[:unique_viewer_logins],
        viewer_samples_total: result[:viewer_samples_total],
        dedupe_ratio: result[:dedupe_ratio],
        count: result[:count],
        elapsed_ms: elapsed_ms
      )

      result
    end
  end
end
