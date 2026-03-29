# frozen_string_literal: true

FactoryBot.define do
  factory :ccv_snapshot do
    association :stream
    timestamp { Time.current }
    ccv_count { rand(50..5000) }
  end
end
