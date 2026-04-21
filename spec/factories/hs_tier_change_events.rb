# frozen_string_literal: true

FactoryBot.define do
  factory :hs_tier_change_event do
    channel
    stream { nil }
    event_type { "tier_change" }
    from_tier { "needs_review" }
    to_tier { "trusted" }
    hs_before { 55.0 }
    hs_after { 72.0 }
    metadata { {} }
    occurred_at { Time.current }
  end
end
