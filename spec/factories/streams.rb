# frozen_string_literal: true

FactoryBot.define do
  factory :stream do
    channel
    started_at { 3.hours.ago }
    ended_at { 1.hour.ago }
  end
end
