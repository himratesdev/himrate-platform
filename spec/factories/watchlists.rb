# frozen_string_literal: true

FactoryBot.define do
  factory :watchlist do
    user
    sequence(:name) { |n| "Watchlist #{n}" }
  end
end
