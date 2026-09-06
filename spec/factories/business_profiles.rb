# frozen_string_literal: true

FactoryBot.define do
  factory :business_profile do
    user
    org_type { "ooo" }
    company_name { "ООО Тест" }
    inn { "1234567890" }
    sphere { "Игры" }
    authority_confirmed { true }
    status { "draft" }
  end
end
