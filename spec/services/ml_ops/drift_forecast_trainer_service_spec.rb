# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlOps::DriftForecastTrainerService do
  describe ".call" do
    context "когда нет drift events" do
      it "skips все pairs (no baselines created)" do
        result = described_class.call
        expect(result.status).to eq(:ok)
        expect(result.pairs_trained).to eq(0)
        expect(DriftBaseline.count).to eq(0)
      end
    end

    context "когда у pair < MIN_SAMPLES events" do
      it "skip pair (insufficient data)" do
        # Только 4 events resolved для pair = 3 intervals < MIN_SAMPLES-1
        4.times do |i|
          AccessoryDriftEvent.create!(
            destination: "production", accessory: "redis",
            declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
            detected_at: i.hours.ago, resolved_at: (i.hours.ago + 30.minutes),
            status: "resolved"
          )
        end
        result = described_class.call
        expect(result.pairs_skipped).to eq(1)
        expect(result.pairs_trained).to eq(0)
        expect(DriftBaseline.count).to eq(0)
      end
    end

    context "когда у pair >= MIN_SAMPLES events" do
      before do
        # 10 resolved events с интервалами 1h..10h (10 events → 9 intervals)
        10.times do |i|
          AccessoryDriftEvent.create!(
            destination: "production", accessory: "redis",
            declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
            detected_at: (i + 1).hours.ago,
            resolved_at: (i + 1).hours.ago + 30.minutes,
            status: "resolved"
          )
        end
      end

      it "computes baseline + UPSERTs DriftBaseline row" do
        result = described_class.call
        expect(result.pairs_trained).to eq(1)
        baseline = DriftBaseline.find_by(destination: "production", accessory: "redis")
        expect(baseline).to be_present
        expect(baseline.sample_count).to eq(10)
        expect(baseline.algorithm_version).to eq(DriftBaseline::ALGORITHM_VERSION)
      end

      it "mean_interval_seconds в expected range (1h step)" do
        described_class.call
        baseline = DriftBaseline.find_by(destination: "production", accessory: "redis")
        # Mean of 1h gaps = 3600s
        expect(baseline.mean_interval_seconds).to be_within(60).of(3600)
      end

      it "stddev_interval_seconds = 0 при equal intervals" do
        described_class.call
        baseline = DriftBaseline.find_by(destination: "production", accessory: "redis")
        expect(baseline.stddev_interval_seconds).to be_within(60).of(0)
      end

      it "idempotent — повторный run обновляет existing record" do
        described_class.call
        first_id = DriftBaseline.first.id
        described_class.call
        expect(DriftBaseline.count).to eq(1)
        expect(DriftBaseline.first.id).to eq(first_id)
      end
    end

    it "groups events per (destination, accessory) — different pairs separate baselines" do
      [ "redis", "db" ].each do |accessory|
        10.times do |i|
          AccessoryDriftEvent.create!(
            destination: "production", accessory: accessory,
            declared_image: "img:v1", runtime_image: "img:v0",
            detected_at: (i + 1).hours.ago,
            resolved_at: (i + 1).hours.ago + 30.minutes,
            status: "resolved"
          )
        end
      end
      result = described_class.call
      expect(result.pairs_trained).to eq(2)
    end
  end
end
