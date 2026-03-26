# frozen_string_literal: true

FactoryBot.define do
  factory :subscription do
    user
    plan { "premium" }
    status { "active" }
    provider { "yookassa" }
    current_period_end { 30.days.from_now }
  end
end
