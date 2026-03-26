# frozen_string_literal: true

FactoryBot.define do
  factory :tracked_channel do
    user
    channel
    subscription
  end
end
