# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::CategoryPattern do
  let(:channel) { create(:channel) }
  let(:from) { 30.days.ago.to_date }
  let(:to) { Time.current.to_date }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "patterns", param_name: "category_single_threshold_pct", param_value: 95, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)

    Rails.cache.clear
  end

  it "returns empty breakdown when no categories" do
    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:categories]).to be_empty
    expect(result[:single_category]).to be false
  end

  it "aggregates by category with weighted TI/ERV" do
    create(:trends_daily_aggregate, channel: channel, date: 3.days.ago.to_date,
      categories: { "Just Chatting" => 2 }, ti_avg: 75.0, erv_avg_percent: 80.0)
    create(:trends_daily_aggregate, channel: channel, date: 2.days.ago.to_date,
      categories: { "Fortnite" => 1 }, ti_avg: 85.0, erv_avg_percent: 90.0)

    result = described_class.call(channel: channel, from: from, to: to)

    names = result[:categories].map { |c| c[:name] }
    expect(names).to match_array([ "Just Chatting", "Fortnite" ])
    expect(result[:top_category]).to eq("Just Chatting")
    expect(result[:total_streams]).to eq(3)
  end

  it "flags single_category when one dominates" do
    5.times do |i|
      create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date,
        categories: { "Just Chatting" => 10 }, ti_avg: 75.0, erv_avg_percent: 80.0)
    end

    result = described_class.call(channel: channel, from: from, to: to)
    expect(result[:single_category]).to be true
  end

  it "computes deltas against baseline (CR S-2: exclude self from baseline)" do
    other_channel = create(:channel)
    create(:trends_daily_aggregate, channel: other_channel, date: 5.days.ago.to_date,
      categories: { "Fortnite" => 1 }, ti_avg: 70.0, erv_avg_percent: 75.0)
    create(:trends_daily_aggregate, channel: channel, date: 2.days.ago.to_date,
      categories: { "Fortnite" => 1 }, ti_avg: 85.0, erv_avg_percent: 90.0)

    result = described_class.call(channel: channel, from: from, to: to)

    row = result[:categories].find { |c| c[:name] == "Fortnite" }
    # Baseline excludes self → avg только у other_channel = 70. delta = 85 - 70 = 15.
    expect(row[:vs_baseline_ti_delta]).to be_within(0.01).of(15.0)
    expect(row[:vs_baseline_erv_delta]).to be_within(0.01).of(15.0)
  end

  it "baseline nil when no other channels в категории" do
    create(:trends_daily_aggregate, channel: channel, date: 2.days.ago.to_date,
      categories: { "NicheGame" => 1 }, ti_avg: 85.0, erv_avg_percent: 90.0)

    result = described_class.call(channel: channel, from: from, to: to)

    row = result[:categories].find { |c| c[:name] == "NicheGame" }
    expect(row[:vs_baseline_ti_delta]).to be_nil
    expect(row[:vs_baseline_erv_delta]).to be_nil
  end
end
