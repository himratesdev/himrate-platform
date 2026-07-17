# frozen_string_literal: true

FactoryBot.define do
  factory :notify_request do
    sequence(:email) { |n| "notify#{n}@example.com" }
    source { "lk_launch" }
  end
end
