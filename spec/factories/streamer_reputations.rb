# frozen_string_literal: true

FactoryBot.define do
  factory :streamer_reputation do
    channel
    growth_pattern_score { 75.0 }
    follower_quality_score { 80.0 }
    engagement_consistency_score { 70.0 }
    pattern_history_score { 85.0 }
    calculated_at { Time.current }
  end
end
