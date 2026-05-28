# frozen_string_literal: true

# TASK-251.W2b: populate the ChatterProfile cache from Twitch GQL so BotScoringWorker can feed
# per-chatter profile data into BotDetection::Scorer (Account Profile Scoring, signal #11, was
# dead — BotScoringWorker hardcoded `profile: nil`).
#
# Runs on :monitoring (NOT the :signals hot path) so per-chatter GQL fetches never compete with
# signal compute. Profiles are stable (account age / follower count change slowly), so each
# chatter is fetched once per STALE_AFTER and cached cross-stream; BotScoringWorker then reads the
# cache with zero GQL calls. Bounded per run; cron re-runs to warm the cache over time.
class ChatterProfileRefreshWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  LOOKBACK = 2.hours      # "recently active" chatters = those who chatted in this window
  STALE_AFTER = 30.days   # profile data is slow-moving; re-fetch rarely
  MAX_PER_RUN = 350       # ≤10 GQL batches (batch size 35); cron re-runs to clear the backlog

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

  # Recently-active chatter logins without a fresh cached profile. Filtering + LIMIT happen in
  # SQL (NOT EXISTS subquery) so memory stays bounded even though chat_messages is large.
  def logins_to_enrich
    ChatMessage
      .where("chat_messages.timestamp > ?", LOOKBACK.ago)
      .where.not(username: nil)
      .where(
        "NOT EXISTS (SELECT 1 FROM chatter_profiles cp WHERE cp.login = chat_messages.username AND cp.fetched_at > ?)",
        STALE_AFTER.ago
      )
      .distinct
      .limit(MAX_PER_RUN)
      .pluck(:username)
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
