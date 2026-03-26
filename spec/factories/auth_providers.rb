# frozen_string_literal: true

FactoryBot.define do
  factory :auth_provider do
    user
    provider { "twitch" }
    sequence(:uid) { |n| "twitch_uid_#{n}" }
  end
end
