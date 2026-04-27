# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryState, type: :model do
  let(:base_attrs) do
    { destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine" }
  end

  describe "validations" do
    %i[destination accessory current_image].each do |attr|
      it "requires #{attr}" do
        expect(described_class.new(base_attrs.except(attr))).not_to be_valid
      end
    end

    it "enforces uniqueness of (destination, accessory)" do
      described_class.create!(base_attrs)
      duplicate = described_class.new(base_attrs)
      expect(duplicate).not_to be_valid
    end

    it "permits same accessory across different destinations" do
      described_class.create!(base_attrs)
      other = described_class.new(base_attrs.merge(destination: "production"))
      expect(other).to be_valid
    end
  end

  describe "#rollback_available?" do
    it "true when previous_image differs from current" do
      record = described_class.new(
        previous_image: "redis:7.2-alpine", current_image: "redis:7.4-alpine"
      )
      expect(record).to be_rollback_available
    end

    it "false when previous_image is blank" do
      record = described_class.new(previous_image: nil, current_image: "redis:7.4-alpine")
      expect(record).not_to be_rollback_available
    end

    it "false when previous_image == current_image" do
      record = described_class.new(
        previous_image: "redis:7.4-alpine", current_image: "redis:7.4-alpine"
      )
      expect(record).not_to be_rollback_available
    end
  end
end
