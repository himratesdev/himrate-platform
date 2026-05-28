# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Patterns::PatternsBuilder do
  let(:user) { create(:user, locale: "ru") }

  # Helper: создаёт rollup'ы достаточного объёма в выбранный (dow, hour) bucket за N недель.
  # `bucket_secs` распределяется на все (dow ∈ wdays, hour ∈ hour_range) bucket'ы в последних N днях.
  def fill_bucket(wdays:, hours:, secs_per_hour:, days_back: 28)
    today = Date.current
    days_back.times do |d|
      date = today - d
      next unless wdays.include?(date.wday)

      histogram = hours.each_with_object({}) { |h, acc| acc[h.to_s] = secs_per_hour }
      total = secs_per_hour * hours.size
      create(:pva_view_rollup, user: user, date: date, total_seconds: total,
        hour_histogram: histogram)
    end
  end

  it "no-ops when 30d total < MIN_TOTAL_SECONDS_30D" do
    create(:pva_view_rollup, user: user, date: Date.current, total_seconds: 600) # 10m, < 1h

    expect { described_class.call(user.id) }.not_to change(PvaPattern, :count)
  end

  it "emits a weekday-evening rhythm card when ratio ≥ 1.4" do
    # Mon-Tue-Wed evening: 6h × 600s/hr × 4 weeks (3 days × 4 weeks = 12 days) = significant
    fill_bucket(wdays: [ 1, 2, 3 ], hours: (18..23).to_a, secs_per_hour: 600, days_back: 28)
    # Sat-Sun afternoon: 6h × 200s/hr (low) — ratio ≈ 3.0
    fill_bucket(wdays: [ 0, 6 ], hours: (12..17).to_a, secs_per_hour: 200, days_back: 28)

    described_class.call(user.id)

    rhythm = PvaPattern.where(user_id: user.id, pattern_type: "rhythm").to_a
    weekday_evening = rhythm.find { |p| p.title.include?("после рабочих") }
    expect(weekday_evening).to be_present
    expect(weekday_evening.body).to include("%") # interpolated pct
    expect(weekday_evening.actionable).to include("планировать")
    expect(weekday_evening.confidence).to be > 0
    expect(weekday_evening.sentiment_enabled).to be false
  end

  it "does NOT emit weekday-evening rhythm when ratio < 1.4" do
    fill_bucket(wdays: [ 1, 2, 3 ], hours: (18..23).to_a, secs_per_hour: 500, days_back: 28)
    fill_bucket(wdays: [ 0, 6 ], hours: (12..17).to_a, secs_per_hour: 400, days_back: 28) # ratio 1.25

    described_class.call(user.id)

    titles = PvaPattern.where(user_id: user.id).pluck(:title)
    expect(titles).not_to include(a_string_including("после рабочих"))
  end

  it "emits a growth-trend card when last 30d ≥ +20% vs prev 30d" do
    # last 30d: ≥1h total, prev 30d: same scale × 0.5
    (0..29).each do |d|
      create(:pva_view_rollup, user: user, date: Date.current - d, total_seconds: 600)
    end
    (31..60).each do |d|
      create(:pva_view_rollup, user: user, date: Date.current - d, total_seconds: 300)
    end

    described_class.call(user.id)

    growth = PvaPattern.where(user_id: user.id).find { |p| p.title.include?("больше, чем месяц") }
    expect(growth).to be_present
    expect(growth.body).to include("больше времени") # +N% больше
  end

  it "emits a decline-trend card when last 30d ≤ -20% vs prev 30d" do
    (0..29).each do |d|
      create(:pva_view_rollup, user: user, date: Date.current - d, total_seconds: 300)
    end
    (31..60).each do |d|
      create(:pva_view_rollup, user: user, date: Date.current - d, total_seconds: 600)
    end

    described_class.call(user.id)

    decline = PvaPattern.where(user_id: user.id).find { |p| p.title.include?("меньше, чем месяц") }
    expect(decline).to be_present
    expect(decline.body).to include("меньше времени")
  end

  it "atomically replaces rule-based patterns on recompute (sentiment-cards preserved)" do
    fill_bucket(wdays: [ 1, 2, 3 ], hours: (18..23).to_a, secs_per_hour: 600, days_back: 28)
    fill_bucket(wdays: [ 0, 6 ], hours: (12..17).to_a, secs_per_hour: 200, days_back: 28)
    # Сидим sentiment-карту (ML-hook) — должна выжить через recompute.
    sentiment = create(:pva_pattern, user: user, pattern_type: "sentiment",
      title: "Сентимент-карта", sentiment_enabled: true)

    described_class.call(user.id)
    rule_ids_first = PvaPattern.where(user_id: user.id, sentiment_enabled: false).pluck(:id)
    described_class.call(user.id) # recompute

    rule_ids_second = PvaPattern.where(user_id: user.id, sentiment_enabled: false).pluck(:id)
    expect(rule_ids_first & rule_ids_second).to be_empty # replaced (новые id)
    expect(PvaPattern.exists?(sentiment.id)).to be true # sentiment preserved
  end

  it "renders EN cards when user.locale == 'en'" do
    user.update!(locale: "en")
    fill_bucket(wdays: [ 1, 2, 3 ], hours: (18..23).to_a, secs_per_hour: 600, days_back: 28)
    fill_bucket(wdays: [ 0, 6 ], hours: (12..17).to_a, secs_per_hour: 200, days_back: 28)

    described_class.call(user.id)

    titles = PvaPattern.where(user_id: user.id).pluck(:title)
    expect(titles).to include(a_string_including("after workdays"))
  end
end
