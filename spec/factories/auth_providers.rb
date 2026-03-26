# frozen_string_literal: true

FactoryBot.define do
  factory :auth_provider do
    user
    provider { "twitch" }
    sequence(:provider_id) { |n| "twitch_#{n}" }
    is_broadcaster { false }
  end
end
