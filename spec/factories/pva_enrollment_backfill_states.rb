# frozen_string_literal: true

FactoryBot.define do
  factory :pva_enrollment_backfill_state do
    user
    oauth_linked_at { Time.current }
    overall_status { "pending" }
    sources { {} }
    failed_sources { [] }
  end
end
