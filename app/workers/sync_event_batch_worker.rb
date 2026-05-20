# frozen_string_literal: true

# TASK-110 FR-021..023: Batch process sync events from extension cross-device sync.
# Idempotency via SyncEvent.compute_hash + UNIQUE (user_id, event_hash) DB constraint
# (insert_all on_conflict_do_nothing). Per FR-023: same event submitted twice → stored once.
class SyncEventBatchWorker
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 3

  # @param user_id [String] UUID
  # @param events [Array<Hash>] [{event_type, payload, device_fingerprint, synced_at}, ...]
  def perform(user_id, events)
    events = Array(events)
    return if events.empty?

    dropped = 0
    rows = events.filter_map do |event|
      event = event.with_indifferent_access if event.is_a?(Hash)
      synced_at = parse_time(event[:synced_at])
      # N-7 (CR): log dropped events с reason (вместо silent drop).
      unless SyncEvent::EVENT_TYPES.include?(event[:event_type])
        dropped += 1
        Rails.logger.warn("SyncEventBatchWorker: dropped event user=#{user_id} reason=invalid_event_type type=#{event[:event_type].inspect}")
        next nil
      end
      if synced_at.nil?
        dropped += 1
        Rails.logger.warn("SyncEventBatchWorker: dropped event user=#{user_id} reason=invalid_synced_at value=#{event[:synced_at].inspect}")
        next nil
      end

      hash = SyncEvent.compute_hash(
        user_id: user_id,
        event_type: event[:event_type],
        payload: event[:payload] || {},
        synced_at: synced_at
      )

      now = Time.current
      {
        user_id: user_id,
        event_type: event[:event_type],
        event_hash: hash,
        payload: event[:payload] || {},
        device_fingerprint: event[:device_fingerprint],
        synced_at: synced_at,
        created_at: now,
        updated_at: now
      }
    end

    return if rows.empty?

    inserted = SyncEvent.insert_all(rows, unique_by: %i[user_id event_hash])
    Rails.logger.info(
      "SyncEventBatchWorker: user=#{user_id} valid=#{rows.size} accepted=#{inserted.length} " \
      "dropped=#{dropped} duplicates=#{rows.size - inserted.length}"
    )
  end

  private

  def parse_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    return nil if value.blank?

    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
