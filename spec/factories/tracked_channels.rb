# frozen_string_literal: true

FactoryBot.define do
  factory :tracked_channel do
    user
    channel
    subscription
    added_at { Time.current }
    tracking_enabled { true }
  end
end
