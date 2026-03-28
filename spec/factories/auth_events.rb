# frozen_string_literal: true

FactoryBot.define do
  factory :auth_event do
    provider { "twitch" }
    result { "attempt" }
    ip_address { "127.0.0.1" }
    created_at { Time.current }
  end
end
