# frozen_string_literal: true

FactoryBot.define do
  factory :raid_attribution do
    stream
    timestamp { Time.current }
    raid_viewers_count { 50 }
    is_bot_raid { false }
    bot_score { 0.2 }
  end
end
