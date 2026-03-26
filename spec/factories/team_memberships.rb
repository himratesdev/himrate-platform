# frozen_string_literal: true

FactoryBot.define do
  factory :team_membership do
    user
    team_owner factory: :user
    role { "member" }
    status { "active" }
  end
end
