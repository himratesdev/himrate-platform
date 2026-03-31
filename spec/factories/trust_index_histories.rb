# frozen_string_literal: true

FactoryBot.define do
  factory :trust_index_history do
    channel
    stream { nil }
    trust_index_score { 72.0 }
    confidence { 0.85 }
    classification { "needs_review" }
    cold_start_status { "full" }
    erv_percent { 72.0 }
    ccv { 5000 }
    signal_breakdown { { auth_ratio: { value: 0.15, confidence: 0.9 } } }
    rehabilitation_penalty { 0.0 }
    rehabilitation_bonus { 0.0 }
    calculated_at { 1.minute.ago }
  end
end
