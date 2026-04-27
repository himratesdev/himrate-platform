# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe MlOps::DriftForecastInferenceService do
  let(:tmp_dir) { Pathname.new(Dir.mktmpdir("ml_models_spec")) }

  before do
    stub_const("MlOps::DriftForecastInferenceService::MODEL_DIR", tmp_dir)
    allow(AccessoryHostsConfig).to receive(:destinations).and_return([ "staging", "production" ])
  end

  after do
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".call" do
    context "когда нет model artifact" do
      it "returns :no_model graceful (dormant pre-launch)" do
        expect(Open3).not_to receive(:capture2e)
        result = described_class.call
        expect(result.status).to eq(:no_model)
      end
    end

    context "когда model artifact existsна disk" do
      before do
        FileUtils.touch(tmp_dir.join("drift_forecast_v1.bin"))
      end

      it "returns :predicted и persists high-confidence rows" do
        prediction_json = {
          predictions: [
            { predicted_drift_at: 5.days.from_now.iso8601, confidence: 0.75 },
            { predicted_drift_at: 7.days.from_now.iso8601, confidence: 0.45 } # фильтр
          ]
        }.to_json
        allow(Open3).to receive(:capture2e).and_return([
          prediction_json, instance_double(Process::Status, exitstatus: 0)
        ])

        result = described_class.call
        expect(result.status).to eq(:predicted)
        expect(result.model_version).to eq("v1")
        # >= 0.6 confidence фильтр × 16 pairs (8 accessories × 2 destinations) = 16 высоких
        expect(DriftForecastPrediction.count).to be >= 1
        expect(DriftForecastPrediction.where("confidence < ?", 0.6)).to be_empty
      end

      it "returns 0 predictions при Python exit non-zero" do
        allow(Open3).to receive(:capture2e).and_return([
          "error", instance_double(Process::Status, exitstatus: 1)
        ])
        result = described_class.call
        expect(result.status).to eq(:predicted)
        expect(result.predictions_count).to eq(0)
      end
    end
  end
end
