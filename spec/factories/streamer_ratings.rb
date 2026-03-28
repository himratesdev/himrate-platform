# frozen_string_literal: true

FactoryBot.define do
  factory :streamer_rating do
    channel
    rating_score { 75.0 }
    decay_lambda { 0.05 }
    streams_count { 10 }
    calculated_at { Time.current }
  end
end
