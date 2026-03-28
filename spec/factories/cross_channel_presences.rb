# frozen_string_literal: true

FactoryBot.define do
  factory :cross_channel_presence do
    sequence(:username) { |n| "viewer_#{n}" }
    channel
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    message_count { 5 }
  end
end
