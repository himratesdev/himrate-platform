# frozen_string_literal: true

FactoryBot.define do
  factory :recent_channel do
    user
    channel
    opened_at { Time.current }
  end
end
