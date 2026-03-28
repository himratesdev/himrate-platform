# frozen_string_literal: true

FactoryBot.define do
  factory :ti_signal do
    stream
    timestamp { Time.current }
    signal_type { "account_age" }
    value { 0.75 }
  end
end
