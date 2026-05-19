# frozen_string_literal: true

FactoryBot.define do
  factory :dark_period_marker do
    user
    period_start { 1.day.ago }
    period_end { 12.hours.ago }
    n_streams { 3 }
    m_channels { 2 }
    last_extension_seen_at { 2.days.ago }
  end
end
