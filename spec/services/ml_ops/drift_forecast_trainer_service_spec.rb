# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlOps::DriftForecastTrainerService do
  describe ".call" do
    context "when accessory_drift_events count < MIN_EVENTS (50)" do
      it "returns :insufficient_data без shell exec" do
        expect(Open3).not_to receive(:capture2e)
        result = described_class.call
        expect(result.status).to eq(:insufficient_data)
        expect(result.events_count).to eq(0)
      end
    end

    context "when events count >= MIN_EVENTS" do
      before do
        # Все resolved → bypass partial unique index idx_drift_events_open_unique
        # (constraint prevents duplicate open per (destination, accessory) pair).
        50.times do |i|
          AccessoryDriftEvent.create!(
            destination: "production",
            accessory: "redis",
            declared_image: "redis:7.4-alpine",
            runtime_image: "redis:7.2-alpine",
            detected_at: (i + 1).hours.ago,
            resolved_at: i.hours.ago,
            status: "resolved"
          )
        end
        # Stub Python invocation per ADR DEC-13
        allow(Open3).to receive(:capture2e).and_return([
          "training accuracy: 0.83",
          instance_double(Process::Status, exitstatus: 0)
        ])
      end

      it "returns :trained с parsed accuracy" do
        result = described_class.call
        expect(result.status).to eq(:trained)
        expect(result.events_count).to eq(50)
        expect(result.accuracy).to eq(0.83)
      end

      it "model_version label format vN" do
        result = described_class.call
        expect(result.model_version).to match(/\Av\d+\z/)
      end

      it "returns :failed когда Python exits non-zero" do
        allow(Open3).to receive(:capture2e).and_return([
          "import error", instance_double(Process::Status, exitstatus: 1)
        ])
        result = described_class.call
        expect(result.status).to eq(:failed)
      end

      it "returns :failed когда python3 binary missing (Errno::ENOENT)" do
        allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT.new("python3"))
        result = described_class.call
        expect(result.status).to eq(:failed)
      end
    end
  end
end
