# frozen_string_literal: true

module PersonalAnalytics
  module Aggregates
    # TASK-113 BE-2: read-слой над pva_view_rollups (M1-M5). ЕДИНСТВЕННОЕ место PG-rollup-запросов —
    # будущий ClickHouse cutover меняет ТОЛЬКО этот класс (OverviewService от него абстрагирован).
    # Все запросы scoped к одному user_id (per-user analytics).
    class ViewRollupSource
      def initialize(user_id, from, to)
        @user_id = user_id
        @from = from
        @to = to
      end

      def total_seconds
        scoped.sum(:total_seconds)
      end

      # {Date => seconds} по дням окна (M1 sparkline).
      def daily_seconds
        scoped.group(:date).sum(:total_seconds)
      end

      # [{twitch_channel_id, twitch_login, seconds, sessions, last_seen_at}, ...] desc by seconds, limit (M2).
      def top_channels(limit)
        scoped.group(:twitch_channel_id)
              .order(Arel.sql("SUM(total_seconds) DESC"))
              .limit(limit)
              .pluck(:twitch_channel_id, Arel.sql("MAX(twitch_login)"),
                Arel.sql("SUM(total_seconds)"), Arel.sql("SUM(session_count)"), Arel.sql("MAX(last_seen_at)"))
              .map { |tcid, login, secs, sessions, last| channel_hash(tcid, login, secs, sessions, last) }
      end

      # {game_id => seconds}, game_id '' = unknown (M3).
      def category_seconds
        scoped.group(:game_id).sum(:total_seconds)
      end

      # Σ device_seconds jsonb по окну → {device => seconds} (M1 devices).
      def device_seconds
        merge_sum(scoped.pluck(:device_seconds))
      end

      # 7×24 матрица matrix[wday][hour] = seconds (M4 heatmap). wday 0=Sun..6=Sat (Date#wday), hour UTC.
      def heatmap
        matrix = Array.new(7) { Array.new(24, 0) }
        scoped.pluck(:date, :hour_histogram).each do |date, histogram|
          histogram.each { |hour, seconds| matrix[date.wday][hour.to_i] += seconds }
        end
        matrix
      end

      # M5: каналы, впервые увиденные за последние `days` дней (по ВСЕЙ истории, не окну).
      def newly_discovered(days)
        PvaViewRollup.where(user_id: @user_id)
                     .group(:twitch_channel_id)
                     .having("MIN(first_seen_at) >= ?", days.days.ago)
                     .pluck(:twitch_channel_id, Arel.sql("MAX(twitch_login)"),
                       Arel.sql("MIN(first_seen_at)"), Arel.sql("MAX(last_seen_at)"))
                     .map do |tcid, login, first, last|
                       { twitch_channel_id: tcid, twitch_login: login, first_seen_at: first, last_seen_at: last }
                     end
      end

      private

      def scoped
        rel = PvaViewRollup.where(user_id: @user_id)
        @from ? rel.where(date: @from..@to) : rel.where(date: ..@to)
      end

      def channel_hash(twitch_channel_id, login, seconds, sessions, last_seen_at)
        { twitch_channel_id: twitch_channel_id, twitch_login: login,
          seconds: seconds.to_i, sessions: sessions.to_i, last_seen_at: last_seen_at }
      end

      def merge_sum(hashes)
        hashes.each_with_object(Hash.new(0)) { |hash, acc| hash.each { |key, value| acc[key] += value } }
      end
    end
  end
end
