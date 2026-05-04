# frozen_string_literal: true

FactoryBot.define do
  factory :anomaly do
    stream
    timestamp { Time.current }
    # TASK-085 FR-019 (ADR-085 D-2 / ADR-Q2): default 'organic_spike' (semantically neutral)
    # после bot_wave rename. Tests с specific anomaly_type override default.
    anomaly_type { "organic_spike" }
  end
end
