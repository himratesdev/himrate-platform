# frozen_string_literal: true

module PersonalAnalytics
  # TASK-113 BE-3 (FR-007 / M7 log / M9 supporter input): ingest client-captured discrete engagement
  # events (cheer/sub/follow/hype) → pva_engagement_events. Идемпотентно: event_hash =
  # SHA256(user_id|client_event_id), insert_all on_conflict (UNIQUE user_id+event_hash) → ретрай-safe.
  # Mirror SyncEventBatchWorker (drop+log невалидные). twitch_channel_id = стабильный ключ из payload;
  # channel_id(uuid)/twitch_login = enrichment (resolve по channels; login fallback из payload).
  class EngagementIngestWorker
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

    def perform(user_id, events)
      events = Array(events).map { |event| normalize(event) }
      return if events.empty?

      channels = ChannelEnrichment.resolve(events.map { |event| event[:channel_id] })
      rows = events.filter_map { |event| build_row(user_id, event, channels) }
      return if rows.empty?

      PvaEngagementEvent.insert_all(rows, unique_by: %i[user_id event_hash])
    end

    private

    def build_row(user_id, event, channels)
      return drop(user_id, event) unless valid?(event)

      uuid, login = channels[event[:channel_id].to_s]
      now = Time.current
      { user_id: user_id, twitch_channel_id: event[:channel_id].to_s, channel_id: uuid,
        twitch_login: login || event[:login].presence, client_event_id: event[:client_event_id].to_s,
        event_type: event[:event_type], amount: clamp_amount(event[:amount]),
        anonymous: truthy?(event[:anonymous]), source: "client_capture", occurred_at: parse_time(event[:occurred_at]),
        event_hash: PvaEngagementEvent.compute_hash(user_id: user_id, client_event_id: event[:client_event_id].to_s),
        created_at: now, updated_at: now }
    end

    # client_event_id пишется в uuid-колонку → битый формат рушит весь insert_all batch (CR SF-2).
    # Воркер = validation boundary: дропаем (а не падаем) на невалидном UUID.
    def valid?(event)
      event[:channel_id].to_s.present? && event[:client_event_id].to_s.match?(UUID_FORMAT) &&
        parse_time(event[:occurred_at]) && PvaEngagementEvent::EVENT_TYPES.include?(event[:event_type])
    end

    def normalize(event)
      event.is_a?(Hash) ? event.deep_symbolize_keys : {}
    end

    def clamp_amount(value)
      return nil if value.blank?

      amount = value.to_i
      amount.negative? ? nil : amount
    end

    def truthy?(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end

    def parse_time(value)
      return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      return nil if value.blank?

      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def drop(user_id, event)
      Rails.logger.warn("EngagementIngestWorker: dropped user=#{user_id} type=#{event[:event_type].inspect}")
      nil
    end
  end
end
