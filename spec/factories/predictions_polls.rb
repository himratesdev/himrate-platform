# frozen_string_literal: true

FactoryBot.define do
  factory :predictions_poll do
    stream
    event_type { "prediction" }
    participants_count { 150 }
    ccv_at_time { 500 }
    participation_ratio { 0.30 }
    timestamp { Time.current }
  end
end
