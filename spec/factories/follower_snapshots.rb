# frozen_string_literal: true

FactoryBot.define do
  factory :follower_snapshot do
    channel
    timestamp { Time.current }
    followers_count { 1000 }
    new_followers_24h { 50 }
  end
end
