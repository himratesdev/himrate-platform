# frozen_string_literal: true

FactoryBot.define do
  factory :attribution_source do
    sequence(:source) { |n| "test_source_#{n}" }
    enabled { true }
    priority { 50 }
    adapter_class_name { "Trends::Attribution::RaidAdapter" }
    display_label_en { "Test source" }
    display_label_ru { "Тестовый источник" }
    metadata { {} }

    trait :disabled do
      enabled { false }
    end

    trait :raid_organic do
      source { "raid_organic" }
      priority { 10 }
      display_label_en { "Organic raid" }
      display_label_ru { "Органический рейд" }
      metadata { { variant: "organic" } }
    end

    trait :unattributed do
      source { "unattributed" }
      priority { 999 }
      adapter_class_name { "Trends::Attribution::UnattributedFallback" }
      display_label_en { "Unattributed" }
      display_label_ru { "Без атрибуции" }
    end
  end
end
