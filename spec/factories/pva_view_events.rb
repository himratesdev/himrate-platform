# frozen_string_literal: true

FactoryBot.define do
  factory :pva_view_event do
    user
    twitch_channel_id { "12345" }
    twitch_login { "shroud" }
    game_id { "509658" }
    started_at { Time.current }
    seconds { 1800 }
    device { "desktop" }
    source_event_hash { SecureRandom.hex(32) } # 64 hex chars
  end
end
