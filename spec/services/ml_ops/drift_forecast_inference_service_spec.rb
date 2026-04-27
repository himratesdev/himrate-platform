# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlOps::DriftForecastInferenceService do
  describe ".call" do
    context "когда нет baselines" do
      it "returns :ok с 0 predictions" do
        result = described_class.call
        expect(result.status).to eq(:ok)
        expect(result.predictions_count).to eq(0)
      end
    end

    context "когда baseline insufficient (sample_count < MIN_SAMPLES)" do
      before do
        DriftBaseline.create!(
          destination: "production", accessory: "redis",
          mean_interval_seconds: 3600, stddev_interval_seconds: 100,
          sample_count: 3,
          algorithm_version: DriftBaseline::ALGORITHM_VERSION,
          computed_at: Time.current
        )
      end

      it "skips pair" do
        result = described_class.call
        expect(result.pairs_skipped).to eq(1)
        expect(DriftForecastPrediction.count).to eq(0)
      end
    end

    context "когда baseline sufficient + predicted_at в horizon" do
      let!(:last_event) do
        AccessoryDriftEvent.create!(
          destination: "production", accessory: "redis",
          declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
          detected_at: 1.day.ago, status: "open"
        )
      end
      let!(:baseline) do
        DriftBaseline.create!(
          destination: "production", accessory: "redis",
          mean_interval_seconds: 3.days.to_i, stddev_interval_seconds: 1.hour.to_i,
          sample_count: 15,
          algorithm_version: DriftBaseline::ALGORITHM_VERSION,
          computed_at: Time.current
        )
      end

      it "creates prediction row" do
        result = described_class.call
        expect(result.predictions_count).to eq(1)
        prediction = DriftForecastPrediction.first
        expect(prediction.destination).to eq("production")
        expect(prediction.accessory).to eq("redis")
        expect(prediction.confidence).to eq(0.70) # sample_count >= 10
        expect(prediction.model_version).to eq(DriftBaseline::ALGORITHM_VERSION)
        expect(prediction.predicted_drift_at).to be_within(1.minute).of(last_event.detected_at + 3.days)
      end

      it "populates ±1σ confidence interval (CR M-3)" do
        described_class.call
        prediction = DriftForecastPrediction.first
        expect(prediction.predicted_at_lower_bound).to be_within(1.minute).of(last_event.detected_at + 3.days - 1.hour)
        expect(prediction.predicted_at_upper_bound).to be_within(1.minute).of(last_event.detected_at + 3.days + 1.hour)
      end
    end

    context "когда predicted_at вне horizon (>30 days)" do
      before do
        AccessoryDriftEvent.create!(
          destination: "production", accessory: "redis",
          declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
          detected_at: 1.day.ago, status: "open"
        )
        DriftBaseline.create!(
          destination: "production", accessory: "redis",
          mean_interval_seconds: 60.days.to_i, # mean 60d → predicted ~59d из last
          stddev_interval_seconds: 1.hour.to_i,
          sample_count: 15,
          algorithm_version: DriftBaseline::ALGORITHM_VERSION,
          computed_at: Time.current
        )
      end

      it "skips prediction" do
        result = described_class.call
        expect(result.pairs_skipped).to eq(1)
        expect(DriftForecastPrediction.count).to eq(0)
      end
    end

    describe "confidence formula (≥ MIN_CONFIDENCE 0.6 persists)" do
      [ [ 10, 0.70 ], [ 29, 0.70 ], [ 30, 0.85 ], [ 100, 0.85 ] ].each do |sample, expected|
        it "persists prediction с confidence=#{expected} для sample_count=#{sample}" do
          AccessoryDriftEvent.create!(
            destination: "production", accessory: "redis",
            declared_image: "img:v1", runtime_image: "img:v0",
            detected_at: 1.day.ago, status: "open"
          )
          DriftBaseline.create!(
            destination: "production", accessory: "redis",
            mean_interval_seconds: 3.days.to_i, stddev_interval_seconds: 100,
            sample_count: sample,
            algorithm_version: DriftBaseline::ALGORITHM_VERSION,
            computed_at: Time.current
          )
          described_class.call
          prediction = DriftForecastPrediction.first
          expect(prediction.confidence).to eq(expected)
        end
      end

      [ 5, 9 ].each do |sample|
        it "skips prediction для sample_count=#{sample} (confidence 0.5 < MIN_CONFIDENCE)" do
          AccessoryDriftEvent.create!(
            destination: "production", accessory: "redis",
            declared_image: "img:v1", runtime_image: "img:v0",
            detected_at: 1.day.ago, status: "open"
          )
          DriftBaseline.create!(
            destination: "production", accessory: "redis",
            mean_interval_seconds: 3.days.to_i, stddev_interval_seconds: 100,
            sample_count: sample,
            algorithm_version: DriftBaseline::ALGORITHM_VERSION,
            computed_at: Time.current
          )
          described_class.call
          expect(DriftForecastPrediction.count).to eq(0)
        end
      end
    end
  end
end
