# frozen_string_literal: true

FactoryBot.define do
  factory :pva_followed_channel do
    user
    twitch_channel_id { "12345678" }
    twitch_login { "shroud" }
    display_name { "shroud" }
    followed_at { 1.year.ago }
  end
end
