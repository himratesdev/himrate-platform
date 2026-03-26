# frozen_string_literal: true

FactoryBot.define do
  factory :channel do
    sequence(:twitch_id) { |n| "twitch_#{n}" }
    sequence(:login) { |n| "channel_#{n}" }
    display_name { login&.capitalize }
  end
end
