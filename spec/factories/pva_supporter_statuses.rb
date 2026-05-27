# frozen_string_literal: true

FactoryBot.define do
  factory :pva_supporter_status do
    user
    channel_id { SecureRandom.uuid }
    twitch_login { "shroud" }
    tier { "loyal" }
    composite_score { 25.0 }
    computed_at { Time.current }
  end
end
