# frozen_string_literal: true

# TASK-030 FR-003/011: ContextBuilder.
# Collects all data needed for 11 signals from DB into a single Hash.
# Optimized for 1000+ streams: batch-friendly queries, limited windows, no N+1.
# Each query in rescue — one failure doesn't block the rest.

module TrustIndex
  class ContextBuilder
    CCV_SERIES_LIMIT = 30 # max snapshots for 30min window

    # Build context Hash for Registry.compute_all
    def self.build(stream)
      channel = stream.channel

      {
        latest_ccv: fetch_latest_ccv(stream),
        ccv_series_15min: fetch_ccv_series(stream, 15.minutes.ago),
        ccv_series_30min: fetch_ccv_series(stream, 30.minutes.ago),
        ccv_series_10min: fetch_ccv_series(stream, 10.minutes.ago),
        chat_rate_10min: fetch_chat_rate(stream, 10.minutes.ago),
        chat_username_counts_5min: fetch_chat_username_counts(stream, 5.minutes.ago),
        unique_chatters_60min: fetch_unique_chatters(stream),
        # BUG-251.30: registered users present in chat (CommunityTab via Android Client-ID).
        # Source = latest ChattersSnapshot.chatters_present_total. Used by AuthRatio signal #1.
        chatters_present_total: fetch_chatters_present_total(stream),
        bot_scores: fetch_bot_scores(stream),
        channel_protection_config: fetch_config(channel),
        cross_channel_counts: fetch_cross_channel(stream),
        raids: fetch_raids(stream),
        recent_raids: fetch_recent_raids(stream),
        category: resolve_category(stream),
        stream_duration_min: stream_duration(stream)
      }
    end

    class << self
      private

      def fetch_latest_ccv(stream)
        stream.ccv_snapshots.order(timestamp: :desc).pick(:ccv_count)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: latest_ccv failed (#{e.message})")
        nil
      end

      # BUG-251.30: latest CommunityTab presence count for AuthRatio signal #1.
      # Returns nil if no snapshot has presence column populated (e.g., pre-deploy rows
      # or community_tab batch failed for current cycle) — AuthRatio falls back to insufficient.
      def fetch_chatters_present_total(stream)
        stream.chatters_snapshots
          .where.not(chatters_present_total: nil)
          .order(timestamp: :desc)
          .pick(:chatters_present_total)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: chatters_present_total failed (#{e.message})")
        nil
      end

      def fetch_ccv_series(stream, since)
        stream.ccv_snapshots
          .where("timestamp > ?", since)
          .order(:timestamp)
          .limit(CCV_SERIES_LIMIT)
          .pluck(:ccv_count, :timestamp)
          .map { |ccv, ts| { ccv: ccv, timestamp: ts } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: ccv_series failed (#{e.message})")
        []
      end

      # TASK-251.14d: the 4 chat methods now dispatch via Flipper. To keep PG↔CH at TRUE 0-divergence
      # all windowed cutoffs are computed ONCE per public call here (in the dispatch wrapper) and
      # passed by absolute value to both leaves — otherwise PG and CH each evaluate their own
      # `60.minutes.ago` / `24.hours.ago` and drift by ms-to-seconds at the minute boundary, which
      # surfaces phantom divergence and breaks the "flip when divergence stable at 0" gate. PG paths
      # also use `timestamp >= floor` so the minute-bucketed MVs read identically aligned windows
      # (closes CR-198 Nit-2 + CR-206 Should-1/2). See `dispatch_chat` below for flag semantics.
      def fetch_chat_rate(stream, since)
        dispatch_chat(:chat_rate, [ stream, since.beginning_of_minute ])
      end

      def fetch_chat_rate_pg(stream, since)
        ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .where("timestamp >= ?", since)
          .group("date_trunc('minute', timestamp)")
          .count
          .map { |ts, count| { msg_count: count, timestamp: ts } }
          .sort_by { |r| r[:timestamp] }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: chat_rate failed (#{e.message})")
        []
      end

      def fetch_chat_rate_ch(stream, since)
        Clickhouse::ChatQueries.chat_rate(stream, since)
      end

      # TASK-085 FR-017 (ADR-085 D-7): chat username frequency для Shannon entropy.
      # Used by ChatBehavior signal — entropy < 2.0 → chat_entropy_drop alert.
      def fetch_chat_username_counts(stream, since)
        dispatch_chat(:chat_username_counts, [ stream, since.beginning_of_minute ])
      end

      def fetch_chat_username_counts_pg(stream, since)
        ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .where("timestamp >= ?", since)
          .group(:username)
          .count
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: chat_username_counts failed (#{e.message})")
        {}
      end

      def fetch_chat_username_counts_ch(stream, since)
        Clickhouse::ChatQueries.chat_username_counts(stream, since)
      end

      # CR-206 Should-1: capture-once `60.minutes.ago.beginning_of_minute` here so PG and CH leaves
      # share the same absolute cutoff (no drift at the minute boundary between the two queries).
      def fetch_unique_chatters(stream)
        dispatch_chat(:unique_chatters, [ stream, 60.minutes.ago.beginning_of_minute ])
      end

      def fetch_unique_chatters_pg(stream, since)
        ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .where("timestamp >= ?", since)
          .distinct
          .count(:username)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: unique_chatters failed (#{e.message})")
        nil
      end

      def fetch_unique_chatters_ch(stream, since)
        Clickhouse::ChatQueries.unique_chatters(stream, since)
      end

      def fetch_bot_scores(stream)
        PerUserBotScore
          .where(stream_id: stream.id)
          .pluck(:bot_score, :confidence, :classification, :components)
          .map { |score, conf, cls, comp| { bot_score: score, confidence: conf, classification: cls, components: comp || {} } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: bot_scores failed (#{e.message})")
        []
      end

      def fetch_config(channel)
        channel.channel_protection_config
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: config failed (#{e.message})")
        nil
      end

      # Cross-channel: count distinct channels per username in 24h.
      # Uses chat_messages (works during live, not just post-stream).
      # Limited to stream's chatters to keep query bounded.
      CROSS_CHANNEL_CHATTER_LIMIT = 500

      # CR-206 Should-2: capture-once `24.hours.ago` here and pass the absolute timestamp to both
      # leaves. Three separate "now" references (Rails clock + CH server-side `now()` × 2) would
      # drift across the 24h boundary, breaking the parity gate.
      # CR-206 iter-2 nit (sub-second asymmetry): zero out µs so PG (Time, µs precision) and CH
      # (`toDateTime('YYYY-MM-DD HH:MM:SS')`, second precision) filter at the same resolution —
      # otherwise rows landing in the µs±1 band at exactly the 24h edge can produce phantom 1-row
      # deltas in the dual-read divergence log.
      def fetch_cross_channel(stream)
        dispatch_chat(:cross_channel, [ stream, 24.hours.ago.change(usec: 0) ])
      end

      # TASK-251.14d: ORDER BY username added so the PG path picks the same deterministic 500 as
      # the CH path (Clickhouse::ChatQueries.cross_channel) — required for 0-divergence dual-read on
      # high-cardinality streams where the unordered LIMIT 500 was previously arbitrary.
      def fetch_cross_channel_pg(stream, since)
        usernames = ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .distinct
          .order(:username)
          .limit(CROSS_CHANNEL_CHATTER_LIMIT)
          .pluck(:username)

        return {} if usernames.empty?

        ChatMessage
          .where(username: usernames)
          .where("timestamp > ?", since)
          .group(:username)
          .distinct
          .count(:channel_login)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: cross_channel failed (#{e.message})")
        {}
      end

      def fetch_cross_channel_ch(stream, since)
        Clickhouse::ChatQueries.cross_channel(stream, since)
      end

      # TASK-251.14d: dual-flag dispatch for the 4 chat queries.
      # - :chat_reads_clickhouse_dual_read ON → run BOTH paths, log per-call divergence, return the
      #   PG result (safe default). Validation phase: monitor divergence over hours; flip when 0.
      # - :chat_reads_clickhouse ON (without dual_read) → CH only. Combat: signals offload to the
      #   minute-rollups (O(1) reads) and the `:signals` backlog drains.
      # - Both OFF (default) → PG only, unchanged from pre-EPIC behaviour.
      def dispatch_chat(method, args)
        if Flipper.enabled?(:chat_reads_clickhouse_dual_read)
          pg = send("fetch_#{method}_pg", *args)
          ch = safe_ch(method, args)
          log_divergence(method, args.first, pg, ch)
          pg
        elsif Flipper.enabled?(:chat_reads_clickhouse)
          send("fetch_#{method}_ch", *args)
        else
          send("fetch_#{method}_pg", *args)
        end
      end

      def safe_ch(method, args)
        send("fetch_#{method}_ch", *args)
      rescue StandardError => e
        Rails.logger.warn("ContextBuilder dual-read: CH #{method} failed (#{e.class}) — parity comparison skipped for this call")
        nil
      end

      def log_divergence(method, stream, pg, ch)
        return if ch.nil?           # CH call failed — already warned by safe_ch.
        return if pg == ch          # exact match — silent.

        Rails.logger.warn("ContextBuilder dual-read divergence: method=#{method} stream_id=#{stream.id} pg=#{summarize(pg)} ch=#{summarize(ch)}")
      end

      def summarize(value)
        case value
        when nil       then "nil"
        when Integer   then value.to_s
        when Hash      then "Hash(#{value.size})"
        when Array     then "Array(#{value.size})"
        else value.class.name
        end
      end

      def fetch_raids(stream)
        stream.raid_attributions
          .pluck(:timestamp, :is_bot_raid, :raid_viewers_count, :bot_score)
          .map { |ts, bot, viewers, score| { timestamp: ts, is_bot_raid: bot, raid_viewers_count: viewers, bot_score: score } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: raids failed (#{e.message})")
        []
      end

      def fetch_recent_raids(stream)
        stream.raid_attributions
          .where("timestamp > ?", 5.minutes.ago)
          .pluck(:timestamp, :is_bot_raid, :raid_viewers_count)
          .map { |ts, bot, viewers| { timestamp: ts, is_bot_raid: bot, raid_viewers_count: viewers } }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: recent_raids failed (#{e.message})")
        []
      end

      def resolve_category(stream)
        Signals::CategoryResolver.resolve(stream.game_name)
      rescue StandardError
        "default"
      end

      def stream_duration(stream)
        ((Time.current - stream.started_at) / 60).to_i
      rescue StandardError
        0
      end
    end
  end
end
