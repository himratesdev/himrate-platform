# frozen_string_literal: true

# BUG-SCW-CROSS-CHANNEL (2026-06-02): refresh the (username → distinct_channels_24h) digest
# table from ClickHouse once per cycle. A single CH scan replaces the N×M per-stream scans that
# ContextBuilder used to run inside the SignalComputeWorker hot path.
#
# Cron: */5 * * * * (every 5 min — drift on a 24h rolling window is ~0.3%, acceptable for signal
# #4 CrossChannelPresence which already operates on coarse "active in multiple channels" semantics).
# Queue: :monitoring (off the :signal_compute / :signals / :bot_scoring hot paths).
# Gated by Flipper[:cross_channel_digest] so the new path can be enabled/rolled back without redeploy.

class CrossChannelDigestRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  # Cap a single sweep's result set so a runaway 24h window (e.g. flood of one-message chatters)
  # cannot blow PG. Empirically ~50-100k entries per refresh after the HAVING > 1 filter.
  ROW_CAP = 500_000

  # PG upsert batch size — `insert_all` is one INSERT statement per batch, larger batches reduce
  # round-trips but risk hitting the parser limit on very wide statements. 1000 is the sibling
  # convention used by BotScoringWorker / ChatMessageWorker for bulk writes.
  UPSERT_BATCH_SIZE = 1_000

  # Stale-row TTL: rows last refreshed >25h ago are unreachable in the rolling-24h semantics
  # anyway, so delete them to keep the table bounded as the active-chatter set churns.
  STALE_AFTER = 25.hours

  # CR-258 S2: overlap guard. The cron tick fires every 5 min, but the CH aggregation could
  # take longer when CH is under load (the exact scenario this PR exists to mitigate, so
  # transient slowdowns during rollout are realistic). Without a guard the next tick would
  # spawn a SECOND concurrent worker → 2× CH scans on already-stressed CH, defeating the perf
  # gain. The PG side (upsert + delete) is idempotent so no data corruption, only CH load.
  #
  # Redis SETNX with a TTL slightly under the cron interval gives single-flight semantics
  # without the sidekiq-unique-jobs dependency. Sidekiq retries are disabled below (retry: 1
  # = at-most-2 attempts) so a stale lock from a crash unwinds at most one cron tick later.
  OVERLAP_LOCK_KEY = "cross_channel_digest_refresh:lock"
  OVERLAP_LOCK_TTL = 4.minutes.to_i # cron is */5; the next tick lands 5 min later — guard ≈ cron - safety

  def perform
    return unless Flipper.enabled?(:cross_channel_digest)

    # CR-258 iter-2 M-iter2-1: track our acquisition. `ensure` runs unconditionally including
    # the `return unless acquire_lock` short-circuit — without this guard the LOSING tick would
    # DEL the WINNING tick's key on its way out, defeating the overlap guard exactly under the
    # concurrency scenario S2 was added to prevent.
    @lock_held = acquire_lock
    return unless @lock_held

    started = Time.current
    rows = fetch_clickhouse_aggregations
    upserted = upsert_in_batches(rows, started)
    deleted = prune_stale

    duration_ms = ((Time.current - started) * 1000).to_i
    Rails.logger.info(
      "CrossChannelDigestRefreshWorker: scanned=#{rows.size} upserted=#{upserted} pruned=#{deleted} duration_ms=#{duration_ms}"
    )
  ensure
    release_lock if @lock_held
  end

  private

  # CR-258 S2: SETNX with TTL — second concurrent tick will SETNX-fail and return early. On
  # Redis outage, fail OPEN (do the refresh anyway — duplicate CH load is the lesser evil vs.
  # stale digest data, which silently regresses the signal). On fail-open path `@lock_held`
  # remains true so the unconditional release attempt in `ensure` is safe — it'll either DEL
  # a stale lock (we left no lock to release) or no-op on the same Redis-down error path.
  def acquire_lock
    acquired = Sidekiq.redis { |c| c.set(OVERLAP_LOCK_KEY, Process.pid.to_s, nx: true, ex: OVERLAP_LOCK_TTL) }
    unless acquired
      Rails.logger.info("CrossChannelDigestRefreshWorker: overlap lock held, skipping this tick")
      return false
    end
    true
  rescue Redis::BaseError => e
    Rails.logger.warn("CrossChannelDigestRefreshWorker: lock acquire failed (#{e.message}) — proceeding anyway")
    true
  end

  def release_lock
    Sidekiq.redis { |c| c.del(OVERLAP_LOCK_KEY) }
  rescue Redis::BaseError
    nil # best-effort; TTL releases it anyway
  end

  # Single CH aggregation over the 24h `chat_messages` slice. `HAVING c > 1` drops the
  # single-channel chatters (~80-90% of the long tail) — they contribute nothing to a
  # cross-channel-presence signal and just bloat the digest. The cap is the last guard against
  # an unexpected explosion (CH `LIMIT` applies after aggregation).
  def fetch_clickhouse_aggregations
    sql = <<~SQL
      SELECT username, uniqExact(channel_login) AS c
      FROM chat_messages
      WHERE msg_type = 'privmsg'
        AND username != ''
        AND timestamp > now() - INTERVAL 24 HOUR
      GROUP BY username
      HAVING c > 1
      LIMIT #{ROW_CAP}
    SQL

    Clickhouse.client.select(sql).map { |r| { username: r["username"], distinct_channels_24h: r["c"].to_i } }
  rescue Clickhouse::Error => e
    Rails.logger.warn("CrossChannelDigestRefreshWorker: CH aggregation failed (#{e.class}: #{e.message}) — skipping refresh")
    []
  end

  def upsert_in_batches(rows, refreshed_at)
    return 0 if rows.empty?

    upserted = 0
    rows.each_slice(UPSERT_BATCH_SIZE) do |slice|
      payload = slice.map { |r| r.merge(refreshed_at: refreshed_at) }
      CrossChannelDigest.upsert_all(payload, unique_by: :username)
      upserted += slice.size
    end
    upserted
  end

  # Delete digest rows older than STALE_AFTER. The refresh window is rolling-24h, so anything not
  # rewritten this cycle and last touched > 25h ago has effectively disappeared from the active
  # set — pruning keeps the table size bounded as the chatter population churns.
  #
  # CR-258 N2: cutoff is computed at prune time (not at perform start) — if the CH aggregation
  # takes a long time, drifting the cutoff a few seconds is harmless against a 25h margin but
  # is the more obviously-correct expression of "stale = NOT touched in last 25h from now".
  def prune_stale
    cutoff = Time.current - STALE_AFTER
    CrossChannelDigest.where("refreshed_at < ?", cutoff).delete_all
  end
end
