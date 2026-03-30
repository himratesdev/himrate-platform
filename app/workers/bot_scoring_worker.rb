# frozen_string_literal: true

# TASK-027: Per-stream batch bot scoring.
# Triggered by StreamOfflineWorker after stream ends.
# Scores all chatters using BotDetection::Scorer, writes to per_user_bot_scores.
# Flipper[:bot_scoring] gate.

class BotScoringWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals, retry: 3

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

    # Score each chatter
    scores = []
    started_at = Time.current

    usernames.each_slice(BATCH_SIZE) do |batch|
      batch.each do |username|
        context = build_context(
          username: username,
          chatter_data: chatters[username],
          known_bot: known_bot_results[username],
          cross_channel_count: cross_channel_counts[username] || 0
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
  end

  private

  # Collect unique chatters with their IRC data from chat_messages.
  # Returns Hash { username => { user_id:, irc_tags:, chat_stats: } }
  def collect_chatters(stream)
    messages = ChatMessage.where(stream_id: stream.id).where.not(username: nil)

    chatters = {}

    # Per-user aggregation
    messages.select(
      :username,
      "MAX(user_type) as agg_user_type",
      "MAX(subscriber_status) as agg_subscriber_status",
      "BOOL_OR(returning_chatter) as agg_returning_chatter",
      "BOOL_OR(vip) as agg_vip",
      "MAX(badge_info) as agg_badge_info",
      "SUM(bits_used) as agg_bits_used",
      "COUNT(*) as msg_count"
    ).group(:username).each do |row|
      chatters[row.username] = {
        user_id: nil, # from GQL if available
        irc_tags: {
          user_type: row.agg_user_type,
          subscriber_status: row.agg_subscriber_status,
          returning_chatter: row.agg_returning_chatter,
          vip: row.agg_vip,
          badge_info: row.agg_badge_info,
          bits_used: row.agg_bits_used.to_i
        },
        chat_stats: {
          message_count: row.msg_count
        }
      }
    end

    # Per-user entropy and CV timing aggregation (requires 3+ messages)
    enrich_chat_stats(stream, chatters)

    chatters
  end

  # Calculate per-user CV timing and Shannon entropy from raw messages.
  def enrich_chat_stats(stream, chatters)
    # Fetch timestamps per user for CV timing
    user_timestamps = ChatMessage
      .where(stream_id: stream.id, msg_type: "privmsg")
      .where.not(username: nil)
      .order(:username, :timestamp)
      .pluck(:username, :timestamp)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }

    user_timestamps.each do |username, timestamps|
      next unless chatters[username]
      next if timestamps.size < 3

      # CV timing: std(intervals) / mean(intervals)
      intervals = timestamps.each_cons(2).map { |a, b| (b - a).to_f }
      mean = intervals.sum / intervals.size
      if mean > 0
        std = Math.sqrt(intervals.sum { |i| (i - mean)**2 } / intervals.size)
        cv = std / mean
        chatters[username][:chat_stats][:cv_timing] = cv
      end
    end

    # Fetch message texts per user for Shannon entropy
    user_messages = ChatMessage
      .where(stream_id: stream.id, msg_type: "privmsg")
      .where.not(username: nil)
      .where.not(message_text: nil)
      .pluck(:username, :message_text)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }

    user_messages.each do |username, texts|
      next unless chatters[username]
      next if texts.size < 3

      # Shannon entropy over word frequency
      words = texts.join(" ").downcase.split(/\s+/)
      freq = words.tally
      total = words.size.to_f
      entropy = -freq.values.sum { |c| p = c / total; p * Math.log2(p) }
      chatters[username][:chat_stats][:entropy] = entropy
    end

    # Custom emote ratio
    user_emotes = ChatMessage
      .where(stream_id: stream.id, msg_type: "privmsg")
      .where.not(username: nil)
      .where.not(emotes: [ nil, "" ])
      .pluck(:username, :emotes)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }

    user_emotes.each do |username, emote_strings|
      next unless chatters[username]

      total_emotes = emote_strings.sum { |e| e.split("/").size }
      chatters[username][:chat_stats][:custom_emote_ratio] = total_emotes > 0 ? 1.0 : 0.0
    end
  end

  # FR-010: Cross-channel presence from chat_messages (24h window).
  def fetch_cross_channel_counts(usernames)
    return {} if usernames.empty?

    ChatMessage
      .where(username: usernames)
      .where("timestamp > ?", 24.hours.ago)
      .group(:username)
      .distinct
      .count(:channel_login)
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("BotScoringWorker: cross-channel query failed (#{e.message})")
    {}
  end

  def build_context(username:, chatter_data:, known_bot:, cross_channel_count:)
    {
      irc_tags: chatter_data[:irc_tags],
      chat_stats: chatter_data[:chat_stats],
      known_bot: known_bot || { bot: false, confidence: 0.0, sources: [] },
      cross_channel_count: cross_channel_count,
      profile: nil # GQL profile data — future enhancement, graceful without it
    }
  end
end
