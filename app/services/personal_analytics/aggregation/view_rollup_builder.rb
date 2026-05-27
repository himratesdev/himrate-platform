# frozen_string_literal: true

module PersonalAnalytics
  module Aggregation
    # TASK-113 BE-2: rebuild daily viewing rollup для (user, date) из pva_view_events (raw = source of truth).
    # Идемпотентно: пересчитывает бакет ПОЛНОСТЬЮ → upsert_all unique_by (user_id, twitch_channel_id,
    # game_id, date). Зеркало Trends::Aggregation::DailyBuilder. Группировка (twitch_channel_id, game_id):
    # M2 channel · M3 game · M1 sum · M5 first_seen · M4 hour_histogram (UTC hour) · M1 device_seconds.
    class ViewRollupBuilder
      def self.call(user_id, date)
        new(user_id, date).call
      end

      def initialize(user_id, date)
        @user_id = user_id
        @date = date.is_a?(String) ? Date.parse(date) : date
      end

      def call
        events = PvaViewEvent.where(user_id: @user_id, started_at: @date.all_day).to_a
        return if events.empty?

        rows = group_rows(events)
        PvaViewRollup.upsert_all(rows, unique_by: %i[user_id twitch_channel_id game_id date])
      end

      private

      def group_rows(events)
        now = Time.current
        events.group_by { |e| [ e.twitch_channel_id, e.game_id.to_s ] }.map do |(channel, game), evs|
          rollup_row(channel, game, evs).merge(created_at: now, updated_at: now)
        end
      end

      def rollup_row(twitch_channel_id, game_id, evs)
        {
          user_id: @user_id, twitch_channel_id: twitch_channel_id, game_id: game_id, date: @date,
          channel_id: evs.filter_map(&:channel_id).first, twitch_login: evs.filter_map(&:twitch_login).first,
          total_seconds: evs.sum(&:seconds), session_count: evs.size,
          first_seen_at: evs.map(&:started_at).min, last_seen_at: evs.map(&:started_at).max,
          hour_histogram: histogram(evs) { |e| e.started_at.utc.hour.to_s },
          device_seconds: histogram(evs) { |e| e.device.presence || "unknown" }
        }
      end

      # {bucket_key => sum(seconds)} jsonb; bucket_key через блок.
      def histogram(events)
        events.each_with_object(Hash.new(0)) { |e, acc| acc[yield(e)] += e.seconds }
      end
    end
  end
end
