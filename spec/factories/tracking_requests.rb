# frozen_string_literal: true

FactoryBot.define do
  factory :tracking_request do
    channel_login { "teststreamer" }
    user
    status { "pending" }

    trait :guest do
      user { nil }
      extension_install_id { SecureRandom.uuid }
    end

    trait :approved do
      status { "approved" }
    end
  end
end
