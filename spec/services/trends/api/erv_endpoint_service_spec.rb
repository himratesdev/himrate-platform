# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Api::ErvEndpointService do
  let(:channel) { create(:channel) }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "trend", param_name: "direction_rising_slope_min", param_value: 0.1, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "trend", param_name: "direction_declining_slope_max", param_value: -0.1, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "trend", param_name: "confidence_high_r2", param_value: 0.7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "trend", param_name: "confidence_medium_r2", param_value: 0.4, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "min_points_for_forecast", param_value: 14, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "horizon_days_short", param_value: 7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "horizon_days_long", param_value: 30, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "reliability_high_r2", param_value: 0.7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "forecast", param_name: "reliability_medium_r2", param_value: 0.4, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "best_worst", param_name: "min_streams_required", param_value: 3, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  describe "validation" do
    it "raises InvalidPeriod для unknown period" do
      expect { described_class.new(channel: channel, period: "5d") }
        .to raise_error(Trends::Api::BaseEndpointService::InvalidPeriod)
    end

    it "raises InvalidGranularity для unknown granularity" do
      expect { described_class.new(channel: channel, period: "30d", granularity: "hourly") }
        .to raise_error(Trends::Api::BaseEndpointService::InvalidGranularity)
    end

    it "defaults period to 30d when empty" do
      service = described_class.new(channel: channel, period: nil)
      expect(service.call[:data][:period]).to eq("30d")
    end
  end

  describe "response shape (daily granularity)" do
    before do
      5.times do |i|
        date = (30 - i * 2).days.ago.to_date
        create(:trends_daily_aggregate, channel: channel, date: date,
          erv_avg_percent: 70.0 + i * 3, erv_min_percent: 68.0 + i * 3, erv_max_percent: 75.0 + i * 3,
          ccv_avg: 500 + i * 100, ti_avg: 70, ccv_peak: 800 + i * 100)
      end
    end

    it "returns points with expected fields" do
      result = described_class.new(channel: channel, period: "30d").call
      point = result[:data][:points].first

      expect(point).to include(:date, :erv_percent, :erv_min_percent, :erv_max_percent, :erv_absolute, :ccv_avg, :color)
    end

    it "assigns green color для ERV ≥ 80" do
      create(:trends_daily_aggregate, channel: channel, date: 1.day.ago.to_date,
        erv_avg_percent: 85, ti_avg: 70, ccv_avg: 1000)

      result = described_class.new(channel: channel, period: "30d").call
      green_point = result[:data][:points].find { |p| p[:erv_percent] == 85.0 }

      expect(green_point[:color]).to eq("green")
    end

    it "computes summary (current/avg/min/max)" do
      result = described_class.new(channel: channel, period: "30d").call

      expect(result[:data][:summary]).to include(:current, :average, :min, :max, :point_count)
      expect(result[:data][:summary][:point_count]).to eq(5)
    end

    it "includes trend block (even if insufficient for trend — nil fields)" do
      result = described_class.new(channel: channel, period: "30d").call

      expect(result[:data][:trend]).to include(:direction, :slope_per_day, :delta, :r_squared, :confidence)
    end

    it "forecast nil когда <14 points" do
      result = described_class.new(channel: channel, period: "30d").call

      expect(result[:data][:forecast]).to be_nil
    end
  end

  describe "per_stream granularity" do
    it "returns one point per stream" do
      3.times do |i|
        stream = create(:stream, channel: channel)
        create(:trust_index_history, channel: channel, stream: stream,
          trust_index_score: 70, erv_percent: 75 + i, ccv: 500, calculated_at: (5 - i).days.ago)
      end

      result = described_class.new(channel: channel, period: "7d", granularity: "per_stream").call

      expect(result[:data][:points].size).to eq(3)
      expect(result[:data][:points].first).to include(:date, :erv_percent, :erv_absolute, :ccv, :stream_id)
    end
  end

  describe "meta block" do
    it "includes access_level + data_freshness" do
      result = described_class.new(channel: channel, period: "30d").call
      expect(result[:meta]).to include(:access_level, :data_freshness)
    end
  end
end
