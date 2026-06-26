# frozen_string_literal: true

# TASK-030 FR-003/011: ContextBuilder.
# Collects all data needed for the signals from DB into a single Hash.
# Optimized for 1000+ streams: batch-friendly queries, limited windows, no N+1.
# Each query in rescue — one failure doesn't block the rest.

module TrustIndex
  class ContextBuilder
    CCV_SERIES_LIMIT = 30 # max snapshots for 30min window

    # Build context Hash for Registry.compute_all
    def self.build(stream)
      channel = stream.channel
      # CR-323 S1: the digest path (fetch_cross_channel) and the temporal path
      # (fetch_temporal_cross_channel_flags) both need the same "pick 500 chatters present in this
      # stream" CH query. Compute it ONCE here and feed both consumers, so the steady-state (both
      # flags ON) does not run the stream_chatters round-trip twice on the SignalComputeWorker hot
      # path — that doubled scan is exactly what BUG-SCW-CROSS-CHANNEL exists to avoid.
      chatters = shared_stream_chatters(stream)

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
        cross_channel_counts: fetch_cross_channel(stream, chatters),
        temporal_cross_channel_flags: fetch_temporal_cross_channel_flags(stream, chatters),
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

      # PR 1e-A (2026-05-31): post-cutover the 4 chat methods read CH only. Dispatch wrapper,
      # PG leaves, dual-read divergence logging, safe_ch shim and summarize/log helpers all
      # deleted — they existed only to validate the CH cutover. Cutover succeeded
      # (2026-05-31T01:33:00Z, ADR addendum), so a single CH read here is the new SoT.
      # Window cutoffs are still floored to the minute (the MVs aggregate at minute granularity).
      def fetch_chat_rate(stream, since)
        Clickhouse::ChatQueries.chat_rate(stream, since.beginning_of_minute)
      end

      # TASK-085 FR-017 (ADR-085 D-7): chat username frequency для Shannon entropy.
      # Used by ChatBehavior signal — entropy < 2.0 → chat_entropy_drop alert.
      def fetch_chat_username_counts(stream, since)
        Clickhouse::ChatQueries.chat_username_counts(stream, since.beginning_of_minute)
      end

      def fetch_unique_chatters(stream)
        Clickhouse::ChatQueries.unique_chatters(stream, 60.minutes.ago.beginning_of_minute)
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

      # BUG-SCW-CROSS-CHANNEL (2026-06-02): the original implementation ran a 24h full-scan of
      # `chat_messages` (5-8s/call, 82-88% of SignalComputeWorker work) — root cause of the
      # :signal_compute backlog. The digest path pre-computes (username → distinct_channels_24h)
      # once per 5min via CrossChannelIntelligenceWorker; the hot read becomes pick-500-chatters
      # (CH, ~0.3-2s) + bulk_lookup (PG, ~5ms) instead of the second join-style 24h scan.
      #
      # Flipper[:cross_channel_digest] gates the new path so we can enable per-env after the
      # refresh worker has populated the digest at least once (cron */5 min), and roll back
      # instantly by disabling the flag if anything regresses.
      #
      # CR-206 Should-2 (preserved on fallback): capture-once `24.hours.ago` so a single absolute
      # timestamp drives the CH query (a server-side `now()` would drift across the 24h boundary).
      # CR-323 S1: the present-chatter set (CH `stream_chatters`, pick 500) shared by the digest +
      # temporal read paths, fetched at most ONCE per build. Skips the CH round-trip entirely when
      # neither path needs it (both flags OFF → the legacy `cross_channel` fallback handles its own).
      def shared_stream_chatters(stream)
        return [] unless Flipper.enabled?(:cross_channel_digest) || Flipper.enabled?(:temporal_cross_channel)

        # Clickhouse::ChatQueries.stream_chatters self-rescues Clickhouse::Error → [] (no extra guard).
        Clickhouse::ChatQueries.stream_chatters(stream)
      end

      def fetch_cross_channel(stream, chatters)
        if Flipper.enabled?(:cross_channel_digest)
          return {} if chatters.empty?

          # CR-258 M1: fetch_with_baseline post-fills single-channel chatters with 1 so the
          # downstream signal's denominator (`cross_channel_counts.size`) stays stable across
          # the Flipper flip — the digest filters `HAVING c > 1` for compactness, not because
          # those chatters don't count.
          CrossChannelDigest.fetch_with_baseline(chatters)
        else
          Clickhouse::ChatQueries.cross_channel(stream, 24.hours.ago.change(usec: 0))
        end
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: cross_channel digest lookup failed (#{e.message})")
        {}
      end

      # T1-057 FR-B2: per-channel temporal cross-channel bot flags for the chatters present in this
      # stream. Gated by Flipper[:temporal_cross_channel] — while OFF this returns {} so the
      # TemporalCrossChannel signal reports insufficient and is EXCLUDED from the weighted TI score
      # (zero regression on existing channels until the signal is deliberately enabled + calibrated).
      # Mirrors the digest read path: stream_chatters (CH) → bulk_lookup (one PG SELECT).
      #
      # Returns { total_chatters:, flagged: } — `total_chatters` (the full present-chatter set) is the
      # signal's DENOMINATOR; `flagged` (R>=2 subset, usually a handful) is the numerator source. Empty
      # ({}) signals insufficient.
      def fetch_temporal_cross_channel_flags(_stream, chatters)
        return {} unless Flipper.enabled?(:temporal_cross_channel)
        return {} if chatters.empty?

        { total_chatters: chatters.size, flagged: CrossChannelTemporalFlag.bulk_lookup(chatters) }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: temporal_cross_channel lookup failed (#{e.message})")
        {}
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
