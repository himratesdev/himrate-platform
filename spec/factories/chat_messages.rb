# frozen_string_literal: true

FactoryBot.define do
  factory :chat_message do
    association :stream, strategy: :create
    channel_login { "testchannel" }
    username { "testuser#{rand(1000..9999)}" }
    message_text { "Hello world" }
    msg_type { "privmsg" }
    timestamp { Time.current }
    raw_tags { {} }
    is_first_msg { false }
    returning_chatter { false }
    vip { false }
    bits_used { 0 }

    trait :with_full_tags do
      display_name { "TestUser" }
      subscriber_status { "1" }
      badge_info { "subscriber/12" }
      color { "#FF0000" }
      emotes { "25:0-4" }
      twitch_msg_id { SecureRandom.uuid }
      raw_tags { { "display-name" => "TestUser", "subscriber" => "1", "badge-info" => "subscriber/12" } }
    end

    trait :sub do
      msg_type { "sub" }
      raw_tags { { "msg-id" => "sub", "msg-param-cumulative-months" => "1" } }
    end

    trait :resub do
      msg_type { "resub" }
      badge_info { "subscriber/24" }
      raw_tags { { "msg-id" => "resub", "msg-param-cumulative-months" => "24" } }
    end

    trait :roomstate do
      msg_type { "roomstate" }
      username { nil }
      message_text { nil }
      raw_tags { { "followers-only" => "10", "slow" => "30", "subs-only" => "0" } }
    end

    trait :clearchat do
      msg_type { "clearchat" }
      message_text { nil }
      raw_tags { { "ban-duration" => "600" } }
    end

    trait :without_stream do
      stream { nil }
    end
  end
end
