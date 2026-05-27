# frozen_string_literal: true

FactoryBot.define do
  factory :channel_tenure do
    user
    twitch_channel_id { "12345" }
    channel_id { SecureRandom.uuid }
    twitch_login { "shroud" }
    sub_tier { 1 }
    months { 21 }
    streak { 21 }
    anniversary_at { Date.current }
    observed_at { Time.current }
  end
end
