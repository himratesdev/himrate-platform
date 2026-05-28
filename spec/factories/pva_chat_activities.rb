# frozen_string_literal: true

FactoryBot.define do
  factory :pva_chat_activity do
    user
    twitch_channel_id { "12345" }
    twitch_login { "xqc" }
    date { Date.current }
    message_count { 25 }
    emote_counts { { "Kappa" => 10, "LUL" => 5 } }
    first_seen_at { Time.current }
    last_seen_at { Time.current }
  end
end
