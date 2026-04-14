# frozen_string_literal: true

FactoryBot.define do
  factory :watchlist_tags_note do
    watchlist
    channel
    added_at { Time.current }
    tags { [] }
    notes { nil }
  end
end
