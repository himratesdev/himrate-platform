# frozen_string_literal: true

# T1-057: Cross-Channel Intelligence — one ClickHouse-backed worker that derives three bounded
# products from the rolling-24h `chat_messages` slice, each behind its own Flipper gate:
#
#   1. digest  (:cross_channel_digest)   — existing (username → distinct_channels_24h) scalar that
#                                           ContextBuilder reads instead of a hot-path CH scan.
#   2. edges   (:cross_channel_edges)     — overlap edge-ledger (username × channel) → cross_channel
#                                           _presences, the data source for the audience-overlap graph.
#   3. temporal(:temporal_cross_channel)  — tiered co-occurrence bot signal (user in >=3 distinct
#                                           channels within a sliding <=W-second window, R = recurrences)
#                                           → cross_channel_temporal_flags → TemporalCrossChannel TI signal.
#
# Renamed from CrossChannelDigestRefreshWorker (which only did #1) — the cron job is renamed in
# config/initializers/sidekiq_cron.rb with an idempotent destroy of the legacy job name.
#
# Cron: */5 * * * * (queue :monitoring). Single shared overlap-lock (Redis SETNX) guards the whole
# cycle; each section is gated AND failure-isolated independently (§5): a CH failure in one section
# logs and leaves that section's prior PG snapshot intact (skips its prune) without aborting the
# others. All three read the SAME 24h partition (partition-pruned, skinny columns ~106 MiB working
# set) — snapshot-recompute (OVERWRITE), never an incremental accumulator.
class CrossChannelIntelligenceWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  # Cap a single sweep's result set so a runaway 24h window cannot blow PG. Applies to the digest
  # and edge scans (the temporal scan is self-bounding via HAVING event_count >= 2).
  ROW_CAP = 500_000

  # PG upsert batch size — one INSERT per batch; 1000 is the sibling convention.
  UPSERT_BATCH_SIZE = 1_000

  # Stale-row TTL: rows last refreshed/seen >25h ago are unreachable in rolling-24h semantics, so
  # delete them to keep each table bounded as the active-chatter set churns.
  STALE_AFTER = 25.hours

  # Overlap cohort cap (BR-2): users present in >BOT_CAP_OVERLAP distinct channels per 24h are
  # bots/omnipresent and are kept OUT of the co-viewing overlap GRAPH (genuine audience only).
  # Aligned with TrustIndex::Signals::CrossChannelPresence::SUSPICIOUS_CHANNELS (30). Tunable.
  BOT_CAP_OVERLAP = 30

  # Temporal co-occurrence window (FR-B). Probe-2 (run 28142215588): W=5/10/15s give near-identical
  # tiers — malicious bots fire sub-5s — so 5s is sufficient at the lowest cost. Tunable.
  WINDOW_SECONDS = 5

  # Tiered-repetition thresholds (PO 2026-06-25). R = recurrence count of >=3-channel events / 24h.
  TIER_CONFIRMED = 7 # "bot 10/10"
  TIER_YELLOW    = 4 # "practically 100% bot"
  TIER_FLAG      = 3
  TIER_WATCH     = 2 # query already filters >=2; below this the user is absent (implicit "none")

  # CR-258 S2: overlap guard. Single-flight via Redis SETNX with a TTL backstop. The 3-section cycle
  # is heavier than the old single digest scan, so the TTL is raised to 6 min (ADR DEC-2): the lock
  # is released in `ensure` on every normal completion/crash, so the TTL only matters for a hard-kill
  # (SIGKILL/OOM); 6 min > a 3-scan cycle yet < 2× cron(10 min) so a stale lock skips at most one tick.
  OVERLAP_LOCK_KEY = "cross_channel_digest_refresh:lock" # key kept stable across the rename
  OVERLAP_LOCK_TTL = 6.minutes.to_i

  def perform
    # Skip BEFORE taking the lock if every section is disabled (per-section gating — NOT a single
    # early-return on digest, so edges/temporal roll out independently of digest).
    return unless any_section_enabled?

    @lock_held = acquire_lock
    return unless @lock_held

    started = Time.current
    digest_ms   = section_timing { compute_digest!(started)   if Flipper.enabled?(:cross_channel_digest) }
    edges_ms    = section_timing { compute_edges!(started)    if Flipper.enabled?(:cross_channel_edges) }
    temporal_ms = section_timing { compute_temporal!(started) if Flipper.enabled?(:temporal_cross_channel) }

    total_ms = ((Time.current - started) * 1000).to_i
    # Structured per-section duration log = the drift-monitoring signal (a Prometheus/StatsD subscriber
    # can attach later; ADR DEC-2). If total_ms approaches OVERLAP_LOCK_TTL, raise the TTL / split cadence.
    Rails.logger.info(
      "CrossChannelIntelligenceWorker: total_ms=#{total_ms} digest_ms=#{digest_ms} edges_ms=#{edges_ms} temporal_ms=#{temporal_ms}"
    )
  ensure
    release_lock if @lock_held
  end

  private

  def any_section_enabled?
    Flipper.enabled?(:cross_channel_digest) ||
      Flipper.enabled?(:cross_channel_edges) ||
      Flipper.enabled?(:temporal_cross_channel)
  end

  def section_timing
    return nil unless block_given?

    t0 = Time.current
    yield
    ((Time.current - t0) * 1000).to_i
  end

  # === Section 1: digest (existing behavior — UNCHANGED) ===========================================
  # Preserves the original CrossChannelDigestRefreshWorker semantics exactly (CH error → [] → prune
  # still runs), so its existing tests and the ContextBuilder digest read path are unaffected.
  def compute_digest!(refreshed_at)
    rows = fetch_clickhouse_aggregations
    upsert_digest_in_batches(rows, refreshed_at)
    prune_digest_stale
  end

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
    Rails.logger.warn("CrossChannelIntelligenceWorker: digest CH aggregation failed (#{e.class}: #{e.message}) — skipping refresh")
    []
  end

  def upsert_digest_in_batches(rows, refreshed_at)
    return 0 if rows.empty?

    upserted = 0
    rows.each_slice(UPSERT_BATCH_SIZE) do |slice|
      payload = slice.map { |r| r.merge(refreshed_at: refreshed_at) }
      CrossChannelDigest.upsert_all(payload, unique_by: :username)
      upserted += slice.size
    end
    upserted
  end

  def prune_digest_stale
    CrossChannelDigest.where("refreshed_at < ?", Time.current - STALE_AFTER).delete_all
  end

  # === Section 2: edges (FR-A) =====================================================================
  # Failure-isolated: a CH error leaves prior edges intact and skips the edge prune (prune-last).
  def compute_edges!(_refreshed_at)
    edges = Clickhouse::ChatQueries.cross_channel_edges(BOT_CAP_OVERLAP, ROW_CAP)
    channel_map = monitored_channel_map
    payload = edges.filter_map do |row|
      channel_id = channel_map[row["channel_login"]]
      next unless channel_id # skip un-monitored / unresolved channels (no silent error)

      {
        username: row["username"],
        channel_id: channel_id,
        stream_id: nil, # 24h-global edge by design (per-stream overlap = CH join, not this table)
        source: "live",
        first_seen_at: row["first_seen"],
        last_seen_at: row["last_seen"],
        message_count: row["message_count"].to_i
      }
    end

    payload.each_slice(UPSERT_BATCH_SIZE) do |slice|
      CrossChannelPresence.upsert_all(slice, unique_by: %i[username channel_id source])
    end
    prune_edges_stale
  rescue Clickhouse::Error => e
    Rails.logger.warn("CrossChannelIntelligenceWorker: edges CH query failed (#{e.class}: #{e.message}) — prior edges kept, prune skipped")
  end

  # Map of downcased login → channel_id. CH channel_login is IRC-lowercase; downcase the PG side too
  # so a mixed-case channels.login can never silently drop an edge (DSV: currently all lowercase,
  # guard is future-proofing).
  def monitored_channel_map
    Channel.pluck(:login, :id).each_with_object({}) { |(login, id), h| h[login.to_s.downcase] = id }
  end

  # Prune only OUR source ('live') — never T1-058's vod-backfill rows.
  def prune_edges_stale
    CrossChannelPresence.where(source: "live").where("last_seen_at < ?", Time.current - STALE_AFTER).delete_all
  end

  # === Section 3: temporal co-occurrence bot signal (FR-B) =========================================
  # Failure-isolated: a CH error leaves prior temporal flags intact and skips the prune.
  def compute_temporal!(refreshed_at)
    rows = Clickhouse::ChatQueries.temporal_co_occurrence(WINDOW_SECONDS)
    payload = rows.map do |row|
      username = row["username"]
      r = row["event_count"].to_i
      {
        username: username,
        event_count: r,
        max_concurrent_channels: row["max_concurrent"].to_i,
        bot_flag_tier: tier_for(r),
        bot_type: BotDetection::KnownPlatformBots.utility?(username) ? "utility" : "spam",
        window_seconds: WINDOW_SECONDS,
        last_event_at: row["last_event_at"],
        refreshed_at: refreshed_at
      }
    end

    payload.each_slice(UPSERT_BATCH_SIZE) do |slice|
      CrossChannelTemporalFlag.upsert_all(slice, unique_by: :username)
    end
    prune_temporal_stale
  rescue Clickhouse::Error => e
    Rails.logger.warn("CrossChannelIntelligenceWorker: temporal CH query failed (#{e.class}: #{e.message}) — prior flags kept, prune skipped")
  end

  def tier_for(r)
    if    r >= TIER_CONFIRMED then "confirmed"
    elsif r >= TIER_YELLOW    then "yellow"
    elsif r >= TIER_FLAG      then "flag"
    else                           "watch" # r >= TIER_WATCH (query filters >= 2)
    end
  end

  def prune_temporal_stale
    CrossChannelTemporalFlag.where("refreshed_at < ?", Time.current - STALE_AFTER).delete_all
  end

  # === Overlap lock (CR-258 S2 — unchanged) ========================================================
  def acquire_lock
    acquired = Sidekiq.redis { |c| c.set(OVERLAP_LOCK_KEY, Process.pid.to_s, nx: true, ex: OVERLAP_LOCK_TTL) }
    unless acquired
      Rails.logger.info("CrossChannelIntelligenceWorker: overlap lock held, skipping this tick")
      return false
    end
    true
  rescue Redis::BaseError => e
    Rails.logger.warn("CrossChannelIntelligenceWorker: lock acquire failed (#{e.message}) — proceeding anyway")
    true
  end

  def release_lock
    Sidekiq.redis { |c| c.del(OVERLAP_LOCK_KEY) }
  rescue Redis::BaseError
    nil # best-effort; TTL releases it anyway
  end
end
