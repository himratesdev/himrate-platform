# frozen_string_literal: true

FactoryBot.define do
  factory :social_profile_snapshot do
    sequence(:twitch_login) { |n| "streamer_#{n}" }
    platform { "telegram" }
    handle { "some_channel" }
    captured_at { Time.current }
    subscribers { 100_000 }
    avg_views { 50_000 }
    view_sub_ratio { 50.0 }
    posts_on_page { 20 }
    metrics { {} }
  end
end
