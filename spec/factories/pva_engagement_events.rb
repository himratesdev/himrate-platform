# frozen_string_literal: true

FactoryBot.define do
  factory :pva_engagement_event do
    user
    channel_id { SecureRandom.uuid }
    twitch_login { "xqc" }
    client_event_id { SecureRandom.uuid }
    event_type { "cheer" }
    amount { 500 }
    anonymous { false }
    source { "client_capture" }
    occurred_at { Time.current }
    event_hash do
      PvaEngagementEvent.compute_hash(user_id: user&.id, client_event_id: client_event_id)
    end
  end
end
