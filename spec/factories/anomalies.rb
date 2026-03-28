# frozen_string_literal: true

FactoryBot.define do
  factory :anomaly do
    stream
    timestamp { Time.current }
    anomaly_type { "bot_wave" }
  end
end
