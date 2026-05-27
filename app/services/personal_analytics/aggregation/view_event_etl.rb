# frozen_string_literal: true

module PersonalAnalytics
  module Aggregation
    # TASK-113 BE-2: ETL SyncEvent stream_view (TASK-110 sync inbox) → pva_view_events (typed,
    # partitioned analytics raw). Идемпотентно: source_event_hash + UNIQUE (user_id, source_event_hash,
    # started_at), insert_all on_conflict_do_nothing → re-run / out-of-order safe. NOT EXISTS отбирает
    # только ещё не загруженные события (использует unique-индекс). twitch_channel_id = стабильный ключ
    # из payload; channel_id(uuid)/twitch_login = enrichment если канал в `channels` (untracked → nil).
    # Returns affected dates (UTC) → ViewRollupBuilder.
    class ViewEventEtl
      BATCH_SIZE = 1_000

      def self.call(user_id)
        new(user_id).call
      end

      def initialize(user_id)
        @user_id = user_id
      end

      def call
        affected_dates = Set.new
        un_etled_events.find_in_batches(batch_size: BATCH_SIZE) do |batch|
          channels = resolve_channels(batch)
          rows = batch.filter_map { |event| build_row(event, channels) }
          next if rows.empty?

          PvaViewEvent.insert_all(rows, unique_by: %i[user_id source_event_hash started_at])
          affected_dates.merge(rows.map { |r| r[:started_at].utc.to_date })
        end
        affected_dates.to_a
      end

      private

      # stream_view SyncEvents юзера, которых ещё нет в pva_view_events (NOT EXISTS по source_event_hash
      # — использует idx_pva_view_source_dedupe).
      def un_etled_events
        SyncEvent
          .where(user_id: @user_id, event_type: "stream_view")
          .where(
            "NOT EXISTS (SELECT 1 FROM pva_view_events pve " \
            "WHERE pve.user_id = sync_events.user_id AND pve.source_event_hash = sync_events.event_hash)"
          )
      end

      def build_row(event, channels)
        payload = event.payload || {}
        twitch_channel_id = payload["channel_id"].to_s
        started_at = parse_time(payload["watched_at"])
        return nil if twitch_channel_id.blank? || started_at.nil?

        uuid, login = channels[twitch_channel_id]
        # pva_view_events = append-only (только created_at, нет updated_at — BE-1 миграция 160001).
        {
          user_id: @user_id, twitch_channel_id: twitch_channel_id, channel_id: uuid, twitch_login: login,
          game_id: payload["game_id"].presence, started_at: started_at, seconds: payload["duration_sec"].to_i,
          device: clamp_device(payload["device"]), source_event_hash: event.event_hash,
          created_at: Time.current
        }
      end

      # Batch-resolve twitch_id → [channels.id, login] (только tracked каналы; один запрос на batch, no N+1).
      def resolve_channels(batch)
        twitch_ids = batch.filter_map { |e| e.payload&.dig("channel_id")&.to_s.presence }.uniq
        return {} if twitch_ids.empty?

        Channel.where(twitch_id: twitch_ids).pluck(:twitch_id, :id, :login)
               .to_h { |tid, id, login| [ tid, [ id, login ] ] }
      end

      def clamp_device(value)
        PvaViewEvent::DEVICES.include?(value) ? value : nil
      end

      def parse_time(value)
        return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
