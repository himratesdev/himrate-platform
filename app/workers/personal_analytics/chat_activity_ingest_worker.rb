# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3 (FR-006 / M6 Communities): ingest client-captured chat-активность snapshots →
  # pva_chat_activities. Идемпотентно BY REPLACE: upsert_all unique (user_id, twitch_channel_id, date)
  # → последний snapshot за день выигрывает (extension шлёт текущий per-(channel,day) счётчик; без
  # raw-chat-storage). created_at НЕ в payload (DB-default, не дрейфует на ON CONFLICT — как rollup builders).
  class ChatActivityIngestWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    MAX_EMOTE_KEYS = 50
    MAX_EMOTE_KEY_LEN = 100

    def perform(user_id, snapshots)
      snapshots = Array(snapshots).map { |snap| normalize(snap) }
      return if snapshots.empty?

      channels = ChannelEnrichment.resolve(snapshots.map { |snap| snap[:channel_id] })
      rows = snapshots.filter_map { |snap| build_row(user_id, snap, channels) }
      return if rows.empty?

      PvaChatActivity.upsert_all(rows, unique_by: %i[user_id twitch_channel_id date])
    end

    private

    def build_row(user_id, snapshot, channels)
      twitch_channel_id = snapshot[:channel_id].to_s
      date = parse_date(snapshot[:date])
      first_seen = parse_time(snapshot[:first_seen_at])
      last_seen = parse_time(snapshot[:last_seen_at])
      return drop(user_id, snapshot) if twitch_channel_id.blank? || date.nil? || first_seen.nil? || last_seen.nil?

      uuid, login = channels[twitch_channel_id]
      { user_id: user_id, twitch_channel_id: twitch_channel_id, channel_id: uuid,
        twitch_login: login || snapshot[:login].presence, date: date,
        message_count: [ snapshot[:message_count].to_i, 0 ].max, emote_counts: sanitize_emotes(snapshot[:emote_counts]),
        first_seen_at: first_seen, last_seen_at: last_seen, updated_at: Time.current }
    end

    # {emote => count}: non-negative int, ТОП-N по частоте (не по порядку вставки — CR Nit-3),
    # ключ cap'нут по длине (DoS guard).
    def sanitize_emotes(value)
      return {} unless value.is_a?(Hash)

      value.transform_values { |count| [ count.to_i, 0 ].max }
           .sort_by { |_emote, count| -count }.first(MAX_EMOTE_KEYS)
           .to_h { |emote, count| [ emote.to_s[0, MAX_EMOTE_KEY_LEN], count ] }
    end

    def normalize(snapshot)
      snapshot.is_a?(Hash) ? snapshot.deep_symbolize_keys : {}
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def drop(user_id, snapshot)
      Rails.logger.warn("ChatActivityIngestWorker: dropped user=#{user_id} channel=#{snapshot[:channel_id].inspect}")
      nil
    end
  end
end
