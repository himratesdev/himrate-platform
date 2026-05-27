# frozen_string_literal: true

FactoryBot.define do
  factory :pva_pattern do
    user
    pattern_type { "rhythm" }
    title { "Ты смотришь больше после рабочих дней" }
    body { "Активность в пн-вт-ср вечером выше на 64%, чем в выходные днём." }
    actionable { "Попробуй планировать стримы заранее." }
    confidence { 0.92 }
    sentiment_enabled { false }
    computed_at { Time.current }
  end
end
