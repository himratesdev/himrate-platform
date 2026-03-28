# frozen_string_literal: true

FactoryBot.define do
  factory :billing_event do
    user
    event_type { "payment_succeeded" }
    sequence(:stripe_event_id) { |n| "evt_test_#{n}" }
    amount { 9.99 }
    currency { "USD" }
  end
end
