# frozen_string_literal: true

FactoryBot.define do
  factory :trends_daily_aggregate do
    channel
    sequence(:date) { |n| n.days.ago.to_date }
    ti_avg { 75.0 }
    ti_std { 5.0 }
    ti_min { 70.0 }
    ti_max { 80.0 }
    erv_avg_percent { 82.0 }
    erv_min_percent { 75.0 }
    erv_max_percent { 90.0 }
    ccv_avg { 1500 }
    ccv_peak { 2200 }
    streams_count { 1 }
    botted_fraction { 0.05 }
    classification_at_end { "trusted" }
    categories { { "Just Chatting" => 1 } }
    signal_breakdown { { "auth_ratio" => 0.78 } }
    schema_version { 2 }

    trait :with_discovery do
      discovery_phase_score { 0.85 }
    end

    trait :with_coupling do
      follower_ccv_coupling_r { 0.78 }
    end

    trait :tier_change do
      tier_change_on_day { true }
    end

    trait :best do
      is_best_stream_day { true }
    end

    trait :worst do
      is_worst_stream_day { true }
    end
  end
end
