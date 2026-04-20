# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::TrendCalculator do
  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "trend", param_name: "direction_rising_slope_min", param_value: 0.1, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "trend", param_name: "direction_declining_slope_max", param_value: -0.1, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "trend", param_name: "confidence_high_r2", param_value: 0.7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "trend", param_name: "confidence_medium_r2", param_value: 0.4, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  describe ".call" do
    it "classifies rising when slope above threshold with high confidence" do
      points = (0..9).map { |i| [ i.to_f, 60.0 + i * 0.5 ] } # slope=0.5, perfectly linear
      result = described_class.call(points)

      expect(result[:direction]).to eq("rising")
      expect(result[:confidence]).to eq("high")
      expect(result[:slope_per_day]).to be > 0.4
      expect(result[:delta]).to eq(4.5)
    end

    it "classifies declining for slope below negative threshold" do
      points = (0..9).map { |i| [ i.to_f, 80.0 - i * 0.5 ] }
      result = described_class.call(points)

      expect(result[:direction]).to eq("declining")
      expect(result[:delta]).to eq(-4.5)
    end

    it "classifies flat in symmetric narrow band" do
      points = (0..9).map { |i| [ i.to_f, 70.0 + i * 0.01 ] }
      result = described_class.call(points)

      expect(result[:direction]).to eq("flat")
    end

    it "returns empty shape for <2 points" do
      result = described_class.call([ [ 0, 70 ] ])

      expect(result[:direction]).to be_nil
      expect(result[:n_points]).to eq(1)
    end

    it "returns empty shape when all x values identical" do
      result = described_class.call([ [ 1, 70 ], [ 1, 75 ], [ 1, 80 ] ])

      expect(result[:direction]).to be_nil
    end

    it "low confidence when R² below medium threshold" do
      # Pattern with zero correlation — alternating noise
      points = [ [ 0.0, 70.0 ], [ 1.0, 75.0 ], [ 2.0, 70.0 ], [ 3.0, 75.0 ], [ 4.0, 70.0 ] ]
      result = described_class.call(points)

      expect(result[:confidence]).to eq("low")
    end
  end
end
