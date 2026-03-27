# frozen_string_literal: true

FactoryBot.define do
  factory :notification do
    user
    type { "stream_ended" }
  end
end
