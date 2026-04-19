# frozen_string_literal: true

FactoryBot.define do
  factory :anomaly_attribution do
    anomaly
    source { "raid_organic" }
    confidence { 0.85 }
    raw_source_data { {} }
    attributed_at { Time.current }
  end
end
