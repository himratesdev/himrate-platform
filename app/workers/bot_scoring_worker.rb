# frozen_string_literal: true

# TASK-027: Per-stream batch bot scoring.
# Triggered by StreamOfflineWorker after stream ends.
# Scores all chatters using BotDetection::Scorer, writes to per_user_bot_scores.
# Flipper[:bot_scoring] gate.

class BotScoringWorker
  include Sidekiq::Job
  # Phase 5 root cause (2026-05-31): :signals queue runs 700k+ backlog of SignalComputeWorker
  # rebuilds, so bot-scoring jobs enqueued by LiveBotScoringWorker cron land in the tail and
  # never reach workers in time. Dedicated :bot_scoring queue (weight 6 — Sidekiq weighted-random,
  # ≈17% of fetch slots vs :signals weight 5; queue volume tiny so it drains within seconds even
  # at fractional fetch share). Keeps PerUserBotScore fresh for the chat_behavior /
  # known_bot_match / account_profile_scoring signals on live streams.
  sidekiq_options queue: "bot_scoring", retry: 3

  BATCH_SIZE = 1000

  def perform(stream_id)
    return unless Flipper.enabled?(:bot_scoring)

    stream = Stream.find_by(id: stream_id)
    unless stream
      Rails.logger.warn("BotScoringWorker: stream #{stream_id} not found")
      return
    end

    chatters = collect_chatters(stream)
    if chatters.empty?
      Rails.logger.info("BotScoringWorker: stream #{stream_id} has 0 chatters, skipping")
      return
    end

    scorer = BotDetection::Scorer.new
    known_bot_service = KnownBotService.new
    usernames = chatters.keys

    # Batch known bot check
    known_bot_results = known_bot_service.check_batch(usernames)

    # Cross-channel presence (FR-010): count distinct channels per user in last 24h
    cross_channel_counts = fetch_cross_channel_counts(usernames)

    # TASK-251.W2b: per-chatter profile from the ChatterProfile cache (populated off the :signals
    # hot path by ChatterProfileRefreshWorker). Read-only here — zero GQL calls in bot scoring.
    # Feeds Scorer#score_profile → Account Profile Scoring (#11). Graceful for un-cached chatters.
    profiles = fetch_chatter_profiles(usernames)

    # Score each chatter
    scores = []
    started_at = Time.current

    usernames.each_slice(BATCH_SIZE) do |batch|
      batch.each do |username|
        context = build_context(
          username: username,
          chatter_data: chatters[username],
          known_bot: known_bot_results[username],
          cross_channel_count: cross_channel_counts[username] || 0,
          profile: profiles[username]
        )

        result = scorer.score(username, context)

        scores << {
          id: SecureRandom.uuid,
          stream_id: stream.id,
          username: username,
          user_id: chatters[username][:user_id],
          bot_score: result.score,
          confidence: result.confidence,
          classification: result.classification,
          components: result.components
        }
      end
    end

    # Batch upsert
    if scores.any?
      PerUserBotScore.upsert_all(
        scores,
        unique_by: %i[stream_id username],
        update_only: %i[bot_score confidence classification components]
      )
    end

    duration = ((Time.current - started_at) * 1000).to_i
    summary = scores.group_by { |s| s[:classification] }.transform_values(&:count)
    Rails.logger.info(
      "BotScoringWorker: stream #{stream_id} scored #{scores.size} chatters in #{duration}ms — #{summary.inspect}"
    )

    # TASK-030 FR-007: Final signal compute with complete bot scores (force=true skips throttle)
    SignalComputeWorker.perform_async(stream.id, true)
  end

  private

  # PR 1e-A (2026-05-31): switched from PG ChatMessage queries to ClickHouse via
  # Clickhouse::ChatQueries. Same return shape ({ username => { irc_tags:, chat_stats: } }),
  # CH column-store is materially cheaper for the per-stream group-bys on 95k+ msg streams
  # AND keeps the data path single-source (PG chat_messages will be dropped in PR 1e-B).
  #
  # CR-231 iter-2 N3: we mutate each Hash returned by chatter_aggregations to inject :user_id.
  # The CH method's docstring describes the base shape only; the worker widens the entry shape
  # for its downstream Scorer (which expects :user_id). Kept here (not in CH method) because
  # :user_id is a worker-pipeline concern, not a chat-query primitive.
  def collect_chatters(stream)
    chatters = Clickhouse::ChatQueries.chatter_aggregations(stream)
    chatters.each_value { |entry| entry[:user_id] = nil }

    # Per-user entropy and CV timing aggregation (requires 3+ messages)
    enrich_chat_stats(stream, chatters)

    chatters
  end

  # Per-user CV timing + Shannon entropy + custom-emote signal.
  #
  # PR #261 (2026-06-02 perf-debt) consolidated three separate CH full-scans into ONE via
  # `chatter_raw_data`. The pre-261 implementation (three methods on ChatQueries — timestamps,
  # messages, emotes — each 549-2084ms) was the heaviest portion of BSW#perform (~1.6s of 3-7s
  # typical). Consolidated scan returns same per-user arrays in a single round-trip / one disk
  # pass. The three legacy methods were removed entirely in PR #263 (Phase 3 H) — no callers
  # remained after #261 cutover.
  def enrich_chat_stats(stream, chatters)
    raw = Clickhouse::ChatQueries.chatter_raw_data(stream)
    raw.each do |username, data|
      next unless chatters[username]

      # CV timing: std(intervals) / mean(intervals). Requires ≥3 timestamps for one interval pair.
      if data[:timestamps].size >= 3
        intervals = data[:timestamps].each_cons(2).map { |a, b| (b - a).to_f }
        mean = intervals.sum / intervals.size
        if mean > 0
          std = Math.sqrt(intervals.sum { |i| (i - mean)**2 } / intervals.size)
          chatters[username][:chat_stats][:cv_timing] = std / mean
        end
      end

      # Shannon entropy over word frequency. Requires ≥3 non-empty messages for stable signal.
      if data[:messages].size >= 3
        words = data[:messages].join(" ").downcase.split(/\s+/)
        freq = words.tally
        total = words.size.to_f
        entropy = -freq.values.sum { |c| p = c / total; p * Math.log2(p) }
        chatters[username][:chat_stats][:entropy] = entropy
      end

      # CR M1 (PR #261 iter-2): preserve OLD `chatter_emotes` SQL semantics — the legacy method
      # filtered `WHERE emotes != ''` server-side, so users with no non-empty emote rows never
      # entered the Ruby loop, leaving `:has_custom_emotes` UNSET (nil) in their chat_stats.
      #
      # `BotDetection::Scorer#score_chat_behavior` (`bot_detection/scorer.rb:150`) has a
      # `:zero_custom_emotes` branch guarded by `has_custom_emotes && msg_count>=8 && has_custom_emotes==0.0`.
      # Setting 0.0 (truthy in Ruby) instead of leaving nil flips ≥8-msg no-emote chatters into a
      # +0.35 bot-suspicion penalty they did NOT carry under the old path — a silent scoring
      # regression invisible at the CH-perf layer.
      #
      # Gate the write on `emote_strings.any?` so the marker is set ONLY for chatters who actually
      # have non-empty emote payloads (mirrors the old SQL filter exactly). Total emote count is
      # not needed: any non-empty row has `.split("/").size >= 1` by definition.
      chatters[username][:chat_stats][:has_custom_emotes] = 1.0 if data[:emote_strings].any?
    end
  end

  # FR-010: Cross-channel presence from chat_messages (24h window).
  # PR 1e-A: ClickHouse-backed (matches Clickhouse::ChatQueries.chatter_cross_channel_counts).
  # CR-258 S1: Flipper[:cross_channel_digest] also routes BSW through the same digest used by
  # ContextBuilder — same 24h window, same shape, same `fetch_with_baseline` semantics (so
  # single-channel chatters return 1, preserving the legacy contract). The legacy CH path
  # remains as the fallback when the flag is OFF (rollback-safe).
  def fetch_cross_channel_counts(usernames)
    return {} if usernames.empty?

    if Flipper.enabled?(:cross_channel_digest)
      CrossChannelDigest.fetch_with_baseline(usernames)
    else
      Clickhouse::ChatQueries.chatter_cross_channel_counts(usernames, 24.hours.ago)
    end
  end

  # TASK-251.W2b: look up cached Twitch profiles for the scored chatters (one query, no N+1,
  # no GQL). Returns { username => scorer_profile_hash }; un-cached chatters are simply absent
  # (Scorer#score_profile is a no-op on nil profile).
  def fetch_chatter_profiles(usernames)
    ChatterProfile.where(login: usernames).index_by(&:login).transform_values(&:to_scorer_profile)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("BotScoringWorker: chatter profile lookup failed (#{e.message})")
    {}
  end

  def build_context(username:, chatter_data:, known_bot:, cross_channel_count:, profile: nil)
    {
      irc_tags: chatter_data[:irc_tags],
      chat_stats: chatter_data[:chat_stats],
      known_bot: known_bot || { bot: false, confidence: 0.0, sources: [] },
      cross_channel_count: cross_channel_count,
      profile: profile
    }
  end
end
