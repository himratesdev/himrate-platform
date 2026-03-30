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
        latest_chatters: fetch_latest_chatters(stream),
        ccv_series_15min: fetch_ccv_series(stream, 15.minutes.ago),
        ccv_series_30min: fetch_ccv_series(stream, 30.minutes.ago),
        ccv_series_10min: fetch_ccv_series(stream, 10.minutes.ago),
        chat_rate_10min: fetch_chat_rate(stream, 10.minutes.ago),
        unique_chatters_60min: fetch_unique_chatters(stream),
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

      def fetch_latest_chatters(stream)
        stream.chatters_snapshots.order(timestamp: :desc).pick(:unique_chatters_count)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: latest_chatters failed (#{e.message})")
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

      def fetch_chat_rate(stream, since)
        ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .where("timestamp > ?", since)
          .group("date_trunc('minute', timestamp)")
          .count
          .map { |ts, count| { msg_count: count, timestamp: ts } }
          .sort_by { |r| r[:timestamp] }
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: chat_rate failed (#{e.message})")
        []
      end

      def fetch_unique_chatters(stream)
        ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .where("timestamp > ?", 60.minutes.ago)
          .distinct
          .count(:username)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: unique_chatters failed (#{e.message})")
        nil
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

      def fetch_cross_channel(stream)
        # Get usernames from current stream's chat (limit for performance at 1000+ streams)
        usernames = ChatMessage
          .where(stream_id: stream.id, msg_type: "privmsg")
          .distinct
          .limit(CROSS_CHANNEL_CHATTER_LIMIT)
          .pluck(:username)

        return {} if usernames.empty?

        ChatMessage
          .where(username: usernames)
          .where("timestamp > ?", 24.hours.ago)
          .group(:username)
          .distinct
          .count(:channel_login)
      rescue ActiveRecord::StatementInvalid => e
        Rails.logger.warn("ContextBuilder: cross_channel failed (#{e.message})")
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
