# frozen_string_literal: true

FactoryBot.define do
  factory :score_dispute do
    user
    channel
    submitted_at { Time.current }
    reason { "Score seems inaccurate" }
    resolution_status { "pending" }
  end
end
