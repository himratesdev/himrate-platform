# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::WeekdayPattern do
  let(:channel) { create(:channel) }
  let(:from) { 30.days.ago.to_date }
  let(:to) { Time.current.to_date }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "patterns", param_name: "weekday_pattern_min_days", param_value: 14, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  it "returns insufficient_data when days < min_days_required" do
    5.times do |i|
      create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date, ti_avg: 70, erv_avg_percent: 80)
    end

    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:insufficient_data]).to be true
    expect(result[:min_days_required]).to eq(14)
  end

  it "computes per-weekday averages when enough days" do
    14.times do |i|
      date = (i + 1).days.ago.to_date
      create(:trends_daily_aggregate, channel: channel, date: date, ti_avg: 70 + (date.wday * 2), erv_avg_percent: 80, streams_count: 1)
    end

    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:insufficient_data]).to be false
    expect(result[:weekday_patterns].keys).to match_array(%i[sun mon tue wed thu fri sat])
    expect(result[:weekday_patterns][:sun][:ti_avg]).to eq(70.0)
  end

  it "excludes days with nil ti_avg from count" do
    14.times do |i|
      create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date, ti_avg: nil)
    end

    result = described_class.call(channel: channel, from: from, to: to)
    expect(result[:insufficient_data]).to be true
  end
end
