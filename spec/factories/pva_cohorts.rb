# frozen_string_literal: true

FactoryBot.define do
  factory :pva_cohort do
    user
    suggestions { [ { login: "hasanabi", display_name: "HasanAbi", pct: 73 } ] }
    cohort_method { "co_watch" }
    computed_at { Time.current }
  end
end
