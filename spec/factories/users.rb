# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:username) { |n| "user#{n}" }
    role { "viewer" }
    tier { "free" }
    # T1-060 FR-3: flags derive from the legacy scalars by default so existing specs that
    # `create(:user, role: "streamer")` / `tier: "business"` keep producing streamer/brand
    # behavior once the predicates read the flags. Override explicitly to test divergence.
    is_streamer { role == "streamer" }
    is_brand { tier == "business" }

    trait :streamer do
      role { "streamer" }
      is_streamer { true }
    end

    trait :brand do
      is_brand { true }
    end
  end
end
