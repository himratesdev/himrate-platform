# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:username) { |n| "user#{n}" }
    role { "viewer" }
    tier { "free" }
    # T1-060 FR-3: is_streamer derives from the legacy role scalar by default so existing
    # specs that `create(:user, role: "streamer")` keep producing streamer behavior once the
    # predicate reads the flag. brand? is NOT stored — it derives from business access, so the
    # :brand trait just grants the business tier.
    is_streamer { role == "streamer" }

    trait :streamer do
      role { "streamer" }
      is_streamer { true }
    end

    trait :brand do
      tier { "business" }
    end
  end
end
