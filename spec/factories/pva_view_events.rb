# frozen_string_literal: true

FactoryBot.define do
  factory :pva_view_event do
    user
    twitch_login { "shroud" }
    game_id { "509658" }
    started_at { Time.current }
    seconds { 1800 }
    device { "desktop" }
  end
end
