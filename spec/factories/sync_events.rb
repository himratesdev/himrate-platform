# frozen_string_literal: true

FactoryBot.define do
  factory :sync_event do
    user
    event_type { "stream_view" }
    payload { { channel_id: "12345", watched_at: Time.current.iso8601, duration_sec: 120 } }
    device_fingerprint { "abcd1234deadbeef" }
    synced_at { Time.current }
    event_hash do
      SyncEvent.compute_hash(
        user_id: user&.id,
        event_type: event_type,
        payload: payload,
        synced_at: synced_at
      )
    end
  end
end
