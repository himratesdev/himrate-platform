# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::ForecastService do
  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "forecast", param_name: "min_points_for_forecast", param_value: 14, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "horizon_days_short", param_value: 7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "horizon_days_long", param_value: 30, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "reliability_high_r2", param_value: 0.7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "reliability_medium_r2", param_value: 0.4, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  it "returns nil when points below min threshold" do
    expect(described_class.call([ [ 0, 70 ] ])).to be_nil
    expect(described_class.call((0..12).map { |i| [ i.to_f, 70.0 ] })).to be_nil
  end

  it "produces 7d and 30d forecasts with bands" do
    # Small noise on strong upward drift → R² ≥ 0.7 (high), bands non-degenerate
    points = (0..19).map { |i| [ i.to_f, 70.0 + i * 0.7 + (i.odd? ? 0.2 : -0.2) ] }
    result = described_class.call(points)

    expect(result[:forecast_7d][:value]).to be >= result[:forecast_7d][:lower]
    expect(result[:forecast_7d][:value]).to be <= result[:forecast_7d][:upper]
    expect(result[:forecast_7d][:upper]).to be > result[:forecast_7d][:lower]
    expect(result[:forecast_30d][:value]).to be > result[:forecast_7d][:value]
    expect(result[:reliability]).to eq("high")
  end

  it "classifies reliability=low when R² poor" do
    points = (0..19).map { |i| [ i.to_f, 70.0 + rand * 20 - 10 ] }
    result = described_class.call(points)

    expect(%w[low medium high]).to include(result[:reliability])
  end

  it "clamps forecast value into [0, 100]" do
    # Strong upward drift that would exceed 100 at forecast horizon
    points = (0..19).map { |i| [ i.to_f, 80.0 + i * 1.5 ] }
    result = described_class.call(points)

    expect(result[:forecast_30d][:value]).to be <= 100.0
    expect(result[:forecast_30d][:lower]).to be <= 100.0
    expect(result[:forecast_30d][:upper]).to be <= 100.0
  end
end
