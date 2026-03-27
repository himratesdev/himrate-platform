# frozen_string_literal: true

FactoryBot.define do
  factory :health_score do
    channel
    stream
    health_score { 75.0 }
    calculated_at { Time.current }
    confidence_level { "full" }
  end
end
