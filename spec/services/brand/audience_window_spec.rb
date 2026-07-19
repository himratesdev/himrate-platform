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
end
