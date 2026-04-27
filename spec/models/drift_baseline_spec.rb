# frozen_string_literal: true

require "rails_helper"

RSpec.describe DriftBaseline, type: :model do
  let(:base_attrs) do
    {
      destination: "production",
      accessory: "redis",
      mean_interval_seconds: 3600,
      stddev_interval_seconds: 600,
      sample_count: 10,
      algorithm_version: described_class::ALGORITHM_VERSION,
      computed_at: Time.current
    }
  end

  describe "validations" do
    it "valid с required fields" do
      expect(described_class.new(base_attrs)).to be_valid
    end

    %i[destination accessory algorithm_version computed_at].each do |attr|
      it "requires #{attr}" do
        expect(described_class.new(base_attrs.merge(attr => nil))).not_to be_valid
      end
    end

    it "enforces uniqueness of (destination, accessory)" do
      described_class.create!(base_attrs)
      expect(described_class.new(base_attrs)).not_to be_valid
    end

    it "rejects negative sample_count" do
      expect(described_class.new(base_attrs.merge(sample_count: -1))).not_to be_valid
    end

    it "rejects zero mean_interval_seconds" do
      expect(described_class.new(base_attrs.merge(mean_interval_seconds: 0))).not_to be_valid
    end

    it "permits nil intervals (insufficient data baseline)" do
      record = described_class.new(base_attrs.merge(
        mean_interval_seconds: nil, stddev_interval_seconds: nil, sample_count: 0
      ))
      expect(record).to be_valid
    end
  end

  describe "#sufficient_data?" do
    it "true когда sample_count >= MIN_SAMPLES + mean present" do
      expect(described_class.new(sample_count: 10, mean_interval_seconds: 3600)).to be_sufficient_data
    end

    it "false когда sample_count < MIN_SAMPLES" do
      expect(described_class.new(sample_count: 4, mean_interval_seconds: 3600)).not_to be_sufficient_data
    end

    it "false когда mean_interval_seconds nil" do
      expect(described_class.new(sample_count: 10, mean_interval_seconds: nil)).not_to be_sufficient_data
    end
  end
end
