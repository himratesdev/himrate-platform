# frozen_string_literal: true

# T1-074 (TI v2) — NamedBotEvidence factory (immutable dispute-safe P5 evidence).
FactoryBot.define do
  factory :named_bot_evidence do
    channel
    trust_index_history { association :trust_index_history, channel: channel }
    stream { nil }
    sequence(:username) { |n| "bot_account_#{n}" }
    p_u { 0.94 }
    evidence_reason { "temporal_cross_channel" }
    calculated_at { Time.current }
  end
end
