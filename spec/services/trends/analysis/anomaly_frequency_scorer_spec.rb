# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::AnomalyFrequencyScorer do
  let(:channel) { create(:channel) }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "anomaly_freq", param_name: "elevated_threshold_pct", param_value: 50, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "anomaly_freq", param_name: "reduced_threshold_pct", param_value: -20, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "anomaly_freq", param_name: "baseline_lookback_ratio", param_value: 1.0, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "anomaly_freq", param_name: "min_baseline_streams", param_value: 3, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "anomaly_freq", param_name: "min_confidence_threshold", param_value: 0.4, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  it "verdict=insufficient_baseline when baseline too small" do
    stream = create(:stream, channel: channel)
    create(:anomaly, stream: stream, timestamp: 3.days.ago, confidence: 0.8)

    result = described_class.call(channel: channel, from: 7.days.ago, to: Time.current)

    expect(result[:verdict]).to eq("insufficient_baseline")
    expect(result[:delta_percent]).to be_nil
  end

  it "detects elevated frequency" do
    stream = create(:stream, channel: channel)
    from = 9.days.ago
    to = Time.current
    # Baseline: 3 anomalies 15-17 days ago (outside current window)
    3.times { |i| create(:anomaly, stream: stream, timestamp: (15 + i).days.ago, confidence: 0.8) }
    # Current: 10 anomalies 1-8 days ago (inside current window)
    8.times { |i| create(:anomaly, stream: stream, timestamp: (i + 1).days.ago, confidence: 0.8) }

    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:verdict]).to eq("elevated")
    expect(result[:delta_percent]).to be > 50.0
  end

  it "distribution breaks down by weekday and type" do
    stream = create(:stream, channel: channel)
    from = 11.days.ago
    to = Time.current
    8.times do |i|
      create(:anomaly, stream: stream, timestamp: (i + 1).days.ago, confidence: 0.8, anomaly_type: "bot_wave")
    end
    3.times { |i| create(:anomaly, stream: stream, timestamp: (20 + i).days.ago, confidence: 0.8) }

    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:distribution][:by_type]["bot_wave"]).to eq(8)
    expect(result[:distribution][:by_day_of_week].values.sum).to eq(8)
  end

  it "filters out low-confidence anomalies" do
    stream = create(:stream, channel: channel)
    from = 11.days.ago
    to = Time.current
    5.times { |i| create(:anomaly, stream: stream, timestamp: (i + 1).days.ago, confidence: 0.1) } # below threshold
    5.times { |i| create(:anomaly, stream: stream, timestamp: (i + 1).days.ago, confidence: 0.8) }

    result = described_class.call(channel: channel, from: from, to: to)

    # period_days = 12 → 5 × 30 / 12 = 12.5
    expect(result[:current_per_month]).to be_within(0.5).of(12.5)
  end
end
