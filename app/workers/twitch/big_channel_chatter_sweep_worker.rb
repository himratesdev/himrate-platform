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
#
# 2026-06-03 PR-A3: persist the bigger viewer_logins set into the LATEST
# `ChattersSnapshot` row of the channel's currently-live stream. StreamMonitor
# always writes a fresh snapshot with the 100-capped viewer_logins from the
# single CommunityTab call; we replace that capped set with the union from N
# parallel calls (deduped) so the LONG TAIL is available on disk for future
# consumer wiring (AuthRatio variant that reads viewer_logins, CrossChannelPresence
# direct-PG variant, BotScorer enrichment pass over the deduped set). Today there
# are zero readers of `viewer_logins` — the persistence is forward-looking
# per [[feedback-build-for-years]]: write it once the moment we have the data,
# wire consumers in subsequent PRs without a separate backfill pass.
# Skip persistence when the sweep returned fewer unique chatters than the
# existing snapshot — e.g., transient partial-fail returns 80/100 unique;
# we don't want to regress data. Only `viewer_logins`, `chatters_present_total`,
# `viewers_count_present` are updated; role-bucket counts
# (broadcasters/moderators/vips/staff) are uncapped in single call so the
# sweep doesn't add value there.

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

      persisted = persist_sweep_to_latest_snapshot(channel, result)

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
        elapsed_ms: elapsed_ms,
        persisted: persisted
      )

      result
    end

    private

    # PR-A3: persist the bigger viewer_logins union from the parallel sweep into
    # the latest `ChattersSnapshot` for the channel's currently-live stream.
    # Returns a Hash with `:status` (:no_live_stream | :no_snapshot | :no_gain |
    # :persisted) + counters, or nil if the channel has no live stream.
    #
    # No transaction: ChattersSnapshot update is a single PG UPDATE on a single
    # row. No FK touching, no MV invalidation. Atomic by Rails-default.
    def persist_sweep_to_latest_snapshot(channel, result)
      live_stream = channel.streams.where(ended_at: nil).order(started_at: :desc).first
      return { status: :no_live_stream } unless live_stream

      latest = live_stream.chatters_snapshots.order(timestamp: :desc).first
      return { status: :no_snapshot, stream_id: live_stream.id } unless latest

      sweep_logins = result[:all_logins] || []
      sweep_viewers = result[:viewers] || []
      existing_logins = (latest.viewer_logins || []).to_a

      # Merge: union of existing (which may include role-buckets the sweep didn't
      # touch — staff/broadcasters) + sweep all_logins (which has the bigger
      # viewers[] tail). Set semantics dedupes both sides.
      merged_logins = (existing_logins + sweep_logins).uniq
      merged_size = merged_logins.size
      existing_size = existing_logins.size

      if merged_size <= existing_size
        return {
          status: :no_gain,
          stream_id: live_stream.id,
          existing: existing_size,
          merged: merged_size
        }
      end

      # `chatters_present_total` semantics: prefer Twitch's authoritative `count`
      # (which is uncapped) if larger than what we have, else keep existing.
      new_count = [ latest.chatters_present_total.to_i, result[:count].to_i ].max
      new_count = merged_size if new_count.zero?

      # `viewers_count_present` reflects the deduped viewer-bucket size after sweep.
      new_viewers_present = [ latest.viewers_count_present.to_i, sweep_viewers.uniq.size ].max

      latest.update!(
        viewer_logins: merged_logins,
        chatters_present_total: new_count,
        viewers_count_present: new_viewers_present
      )

      Rails.logger.info(
        "[BigChannelChatterSweep:persist] stream=#{live_stream.id} channel=#{channel.login} " \
        "viewer_logins #{existing_size}→#{merged_size} (+#{merged_size - existing_size}) " \
        "chatters_present_total→#{new_count} viewers_count_present→#{new_viewers_present}"
      )

      {
        status: :persisted,
        stream_id: live_stream.id,
        existing: existing_size,
        merged: merged_size,
        delta: merged_size - existing_size,
        chatters_present_total: new_count,
        viewers_count_present: new_viewers_present
      }
    rescue StandardError => e
      Rails.logger.warn("[BigChannelChatterSweep:persist] failed channel=#{channel.login}: #{e.class}: #{e.message}")
      { status: :error, error_class: e.class.name, error_message: e.message }
    end
  end
end
