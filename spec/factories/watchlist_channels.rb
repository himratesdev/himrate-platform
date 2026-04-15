# frozen_string_literal: true

FactoryBot.define do
  factory :watchlist_channel do
    watchlist
    channel
    added_at { Time.current }
  end
end
