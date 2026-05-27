# frozen_string_literal: true

FactoryBot.define do
  factory :pva_weekly_reflection do
    user
    week_start { Date.current.beginning_of_week }
    narrative { "На этой неделе ты провёл 23ч 47м на Twitch. Больше всего — у shroud." }
    moments { [ { icon: "cake", text: "21-я месячная подписка у shroud" } ] }
    reflection_source { "template" }
    generated_at { Time.current }
  end
end
