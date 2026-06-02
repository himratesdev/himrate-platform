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

  def perform
    return unless Flipper.enabled?(:cross_channel_digest)

    started = Time.current
    rows = fetch_clickhouse_aggregations
    upserted = upsert_in_batches(rows, started)
    deleted = prune_stale(started)

    duration_ms = ((Time.current - started) * 1000).to_i
    Rails.logger.info(
      "CrossChannelDigestRefreshWorker: scanned=#{rows.size} upserted=#{upserted} pruned=#{deleted} duration_ms=#{duration_ms}"
    )
  end

  private

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
  def prune_stale(now)
    cutoff = now - STALE_AFTER
    CrossChannelDigest.where("refreshed_at < ?", cutoff).delete_all
  end
end
