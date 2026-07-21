# frozen_string_literal: true

# TASK-251.W2b: populate the ChatterProfile cache from Twitch GQL so BotScoringWorker can feed
# per-chatter profile data into BotDetection::Scorer (Account Profile Scoring, signal #11, was
# dead — BotScoringWorker hardcoded `profile: nil`).
#
# Runs on :monitoring (NOT the :signals hot path) so per-chatter GQL fetches never compete with
# signal compute. Profiles are stable (account age / follower count change slowly), so each
# chatter is fetched once per STALE_AFTER and cached cross-stream; BotScoringWorker then reads the
# cache with zero GQL calls. Bounded per run; cron re-runs to warm the cache over time.
#
# PR-251.14 PR 1e-A follow-up (2026-05-31): post PR #231 chat_messages is CH-only, so the
# "recently active chatters" lookup moved to Clickhouse::ChatQueries.distinct_active_chatters and
# the freshness filter (NOT EXISTS chatter_profiles WHERE fetched_at > STALE_AFTER.ago) runs in
# Ruby against PG. Without this migration the LOOKBACK=2h window drained to empty within hours
# of PR #231 merge → no chatters ever queued for GQL refresh → Account Profile Scoring (#11)
# silently re-broken on every channel.
class ChatterProfileRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  LOOKBACK = 2.hours       # "recently active" chatters = those who chatted in this window
  STALE_AFTER = 30.days    # profile data is slow-moving; re-fetch rarely
  MAX_PER_RUN = 600        # ≤18 GQL batches (batch size 35); cron re-runs to clear the backlog.
                           # BUG-C: raised 350→600 — the :monitoring queue runs empty (0 backlog,
                           # verified 2026-07-21), so throughput headroom exists; the constraint is
                           # Twitch GQL rate-limit, not the box. Adaptive: fetch_profiles rescues.
  LIVE_STREAM_CAP = 500    # bound the live-stream priority CH query (≈concurrent monitored streams)

  # Columns updated on a re-fetch (excludes login = unique key; created_at/updated_at are managed
  # by record_timestamps so created_at is preserved and updated_at is bumped automatically).
  # TASK-251.20: profile_view_count dropped — Twitch deprecated profileViewCount GQL field.
  UPDATE_COLUMNS = %i[twitch_user_id twitch_created_at followers_count follows_count
                      fetched_at].freeze

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:chatter_profile_enrichment)

    logins = logins_to_enrich
    return if logins.empty?

    profiles_by_login = fetch_profiles(logins)
    # Cache ONLY resolved profiles. Unresolved logins (transient GQL failure OR genuine
    # banned/deleted) are deliberately NOT stamped: caching them with null fields would feed
    # fabricated flags into the scorer / #11. "Un-cached" = "no signal" (Scorer no-ops on nil).
    # Anti-retry isn't needed here (unlike monitored channels): an unresolved chatter ages out of
    # the LOOKBACK window once they stop chatting, so it won't be re-selected for long.
    rows = profiles_by_login.filter_map { |login, profile| build_row(login, profile) if profile }
    ChatterProfile.upsert_all(rows, unique_by: :login, update_only: UPDATE_COLUMNS, record_timestamps: true) if rows.any?

    Rails.logger.info("ChatterProfileRefreshWorker: cached #{rows.size}/#{logins.size} chatters (#{logins.size - rows.size} unresolved → retried)")
  end

  private

  # Chatter logins without a fresh cached profile, FRAUD-PRIORITIZED (BUG-C, 2026-07-21).
  #
  # Root cause fixed: the prior `distinct_active_chatters LIMIT 5250` returned an ARBITRARY CH
  # scan-order sample of the ~43k chatters active in the window (no ORDER BY, no fraud-priority),
  # then took the first MAX_PER_RUN. ~88% of active chatters were never even candidates, and a
  # fresh single-channel fake (matvey228666337-class) was profiled only by coincidence — so it
  # counted as a full honest human in EIHC and RAISED the channel's authenticity (Account Profile
  # Scoring #11 gets nil → no-op). We are a bot-detection product blind to a chatter who chatted.
  #
  # Fix: spend the fixed GQL budget on the chatters that actually matter for a LIVE verdict FIRST:
  #   1. PRIORITY — chatters on currently-live MONITORED streams (Stream.active). Their profile
  #      directly drives the live authenticity of a channel we are scoring right now.
  #   2. BACKFILL — general recently-active chatters (feed cross-stream account signals) if budget
  #      remains.
  # Then the same cross-DB freshness filter + MAX_PER_RUN cap. Priority-first order is preserved
  # through `Array#|` (union, dedup, order-stable) and `Array#-` (set-diff, order-stable).
  OVERSAMPLE_LIMIT = MAX_PER_RUN * 15 # cushion for steady-state high cache-hit ratio

  def logins_to_enrich
    live_ids = Stream.active.limit(LIVE_STREAM_CAP).pluck(:id)
    priority = if live_ids.any?
      Clickhouse::ChatQueries.chatters_on_streams(live_ids, limit: OVERSAMPLE_LIMIT)
    else
      []
    end
    backfill = Clickhouse::ChatQueries.distinct_active_chatters(since: LOOKBACK.ago, limit: OVERSAMPLE_LIMIT)
    candidates = priority | backfill # union, priority-first, deduped
    return [] if candidates.empty?

    fresh = ChatterProfile
      .where(login: candidates)
      .where("fetched_at > ?", STALE_AFTER.ago)
      .pluck(:login)
      .to_set
    (candidates - fresh.to_a).first(MAX_PER_RUN) # set-diff preserves priority-first order
  end

  # Batch GQL profile lookups (≤35 logins/request). Returns { login => profile_hash_or_nil }.
  def fetch_profiles(logins)
    result = {}
    logins.each_slice(Twitch::GqlClient::MAX_BATCH_SIZE) do |slice|
      profiles = gql.batch_bot_check(logins: slice)
      slice.each_with_index { |login, i| result[login] = profiles[i] }
    end
    result
  rescue StandardError => e
    Rails.logger.warn("ChatterProfileRefreshWorker: GQL batch failed (#{e.class}: #{e.message.to_s.truncate(120)})")
    result
  end

  # Build an upsert row from a resolved GQL profile (callers pass only resolved profiles).
  def build_row(login, profile)
    {
      login: login, fetched_at: Time.current,
      twitch_user_id: profile[:id],
      twitch_created_at: parse_time(profile[:created_at]),
      followers_count: profile[:followers_count],
      follows_count: profile[:follows_count]
    }
  end

  def parse_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def gql
    @gql ||= Twitch::GqlClient.new
  end
end
