# frozen_string_literal: true

FactoryBot.define do
  factory :pva_engagement_event do
    user
    channel_id { SecureRandom.uuid }
    twitch_login { "xqc" }
    event_type { "cheer" }
    amount { 500 }
    anonymous { false }
    source { "client_capture" }
    occurred_at { Time.current }
    event_hash do
      PvaEngagementEvent.compute_hash(
        user_id: user&.id, event_type: event_type, channel_id: channel_id, occurred_at: occurred_at
      )
    end
  end
end
