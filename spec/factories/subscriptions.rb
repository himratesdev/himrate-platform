# frozen_string_literal: true

FactoryBot.define do
  factory :subscription do
    user
    tier { "premium" }
    plan_type { "per_channel" }
    is_active { true }
    started_at { Time.current }
    cancelled_at { nil }
  end
end
