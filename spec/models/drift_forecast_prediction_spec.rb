# frozen_string_literal: true

require "rails_helper"

RSpec.describe DriftForecastPrediction, type: :model do
  let(:base_attrs) do
    {
      destination: "staging",
      accessory: "redis",
      predicted_drift_at: 5.days.from_now,
      model_version: "v1",
      generated_at: Time.current,
      confidence: 0.75
    }
  end

  describe "validations" do
    it "is valid with required fields" do
      expect(described_class.new(base_attrs)).to be_valid
    end

    %i[destination accessory predicted_drift_at model_version generated_at].each do |attr|
      it "requires #{attr}" do
        expect(described_class.new(base_attrs.merge(attr => nil))).not_to be_valid
      end
    end

    it "permits nil confidence" do
      expect(described_class.new(base_attrs.merge(confidence: nil))).to be_valid
    end

    it "rejects confidence > 1.0" do
      expect(described_class.new(base_attrs.merge(confidence: 1.5))).not_to be_valid
    end

    it "rejects confidence < 0" do
      expect(described_class.new(base_attrs.merge(confidence: -0.1))).not_to be_valid
    end
  end

  describe "scopes" do
    let!(:soon) { described_class.create!(base_attrs.merge(predicted_drift_at: 7.days.from_now)) }
    let!(:far) { described_class.create!(base_attrs.merge(accessory: "db", predicted_drift_at: 60.days.from_now)) }
    let!(:low) { described_class.create!(base_attrs.merge(accessory: "loki", confidence: 0.3, predicted_drift_at: 10.days.from_now)) }

    it ".upcoming returns predictions within 30d default window" do
      expect(described_class.upcoming).to include(soon, low)
      expect(described_class.upcoming).not_to include(far)
    end

    it ".high_confidence returns >= 0.6" do
      expect(described_class.high_confidence).to include(soon, far)
      expect(described_class.high_confidence).not_to include(low)
    end
  end
end
