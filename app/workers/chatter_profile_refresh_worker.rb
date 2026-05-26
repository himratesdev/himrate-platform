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

  def perform
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:chatter_profile_enrichment)

    logins = logins_to_enrich
    return if logins.empty?

    profiles_by_login = fetch_profiles(logins)
    rows = logins.map { |login| build_row(login, profiles_by_login[login]) }

    ChatterProfile.upsert_all(rows, unique_by: :login) if rows.any?

    resolved = profiles_by_login.values.compact.size
    Rails.logger.info("ChatterProfileRefreshWorker: enriched #{logins.size} chatters (#{resolved} resolved, #{logins.size - resolved} unresolved/stamped)")
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

  # Build an upsert row. Resolved logins get full profile data; unresolved (banned/deleted/GQL
  # miss) are still stamped (fetched_at + defaults) so they drop out for STALE_AFTER instead of
  # being re-fetched every run (anti-retry, mirrors ChannelMetadataRefreshWorker).
  def build_row(login, profile)
    now = Time.current
    base = { login: login, fetched_at: now, created_at: now, updated_at: now }
    return base.merge(description_present: false, banner_present: false) unless profile

    base.merge(
      twitch_user_id: profile[:id],
      twitch_created_at: parse_time(profile[:created_at]),
      followers_count: profile[:followers_count],
      follows_count: profile[:follows_count],
      profile_view_count: profile[:profile_view_count],
      videos_count: profile[:videos_count],
      description_present: profile[:description].present?,
      banner_present: profile[:banner_image_url].present?,
      last_broadcast_at: parse_time(profile.dig(:last_broadcast, :started_at))
    )
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
