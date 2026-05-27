# frozen_string_literal: true

FactoryBot.define do
  factory :pva_view_rollup do
    user
    twitch_channel_id { "12345" }
    twitch_login { "shroud" }
    game_id { "509658" }
    date { Date.current }
    total_seconds { 1800 }
    session_count { 1 }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
    hour_histogram { { "20" => 1800 } }
    device_seconds { { "desktop" => 1800 } }
  end
end
