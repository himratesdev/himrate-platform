# frozen_string_literal: true

require "rails_helper"

RSpec.describe Brand::AudienceWindow do
  let(:channel) { create(:channel) }

  it "derives real audience from ccv_avg × erv% + window metadata" do
    # explicit in-window dates — factory sequence(:date) is a leaky global counter
    2.times { |i| create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date, ccv_avg: 10_000, erv_avg_percent: 80.0, ccv_peak: 14_000, streams_count: 2) }
    win = described_class.new(channel)

    a = win.audience
    expect(a[:available]).to be(true)
    expect(a[:real_avg_viewers]).to eq(8_000)   # 10000 × 0.80
    expect(a[:shown_avg_viewers]).to eq(10_000)
    expect(a[:real_pct]).to eq(80.0)
    expect(a[:peak_real]).to eq(11_200)         # 14000 × 0.80
    expect(win.window_meta).to include(days: 30, streams_count: 4, days_covered: 2)
    expect(win.streams_per_week).to eq(0.9)     # 4 / (30/7)
  end

  it "returns available:false for an empty window (never zero-as-data)" do
    expect(described_class.new(channel).audience).to eq({ available: false, reason: "insufficient_window" })
    expect(described_class.new(channel).streams_per_week).to be_nil
    expect(described_class.new(channel).window_meta).to include(days: 30, streams_count: 0, days_covered: 0)
  end

  # T1-074 surface-audit (HIGH regression): v2 TDA days write erv_avg_percent/ti_avg NULL and
  # carry erv_avg_count/authenticity_* — the v1-only reads silently dropped them from the window.
  it "reads v2 days natively (erv_avg_count + authenticity_*) — M11b COALESCE parity" do
    create(:trends_daily_aggregate, channel: channel, date: 1.day.ago.to_date,
           ccv_avg: 10_000, ccv_peak: 14_000, streams_count: 2,
           erv_avg_percent: nil, ti_avg: nil, ti_std: nil,
           erv_avg_count: 7_000, authenticity_avg: 70.0, authenticity_std: 4.0,
           authenticity_min: 61.0, authenticity_max: 82.0)
    a = described_class.new(channel).audience

    expect(a[:available]).to be(true)
    expect(a[:real_avg_viewers]).to eq(7_000)   # NATIVE v2 count, not a rescale
    expect(a[:real_pct]).to eq(70.0)
    expect(a[:peak_real]).to eq(9_800)          # 14000 × authenticity 70%
    expect(a[:ti_avg]).to eq(70.0)              # authenticity_avg
    expect(a[:erv_pct_range]).to eq(min: 61.0, max: 82.0)
  end

  it "mixes v1 + v2 days in one window without dropping either" do
    create(:trends_daily_aggregate, channel: channel, date: 1.day.ago.to_date,
           ccv_avg: 10_000, erv_avg_percent: 80.0, streams_count: 1)   # v1 day: real 8000
    create(:trends_daily_aggregate, channel: channel, date: 2.days.ago.to_date,
           ccv_avg: 10_000, erv_avg_percent: nil, erv_avg_count: 6_000,
           authenticity_avg: 60.0, streams_count: 1)                    # v2 day: real 6000
    a = described_class.new(channel).audience

    expect(a[:real_avg_viewers]).to eq(7_000)   # (8000 + 6000) / 2
  end
end
