# frozen_string_literal: true

FactoryBot.define do
  factory :user_event do
    user
    event_type { "registered" }
    metadata { {} }
    occurred_at { Time.current }
  end
end
