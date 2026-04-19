# frozen_string_literal: true

require "rails_helper"

RSpec.describe AttributionSource do
  describe "validations" do
    subject { build(:attribution_source) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:source) }
    it { is_expected.to validate_presence_of(:adapter_class_name) }
    it { is_expected.to validate_presence_of(:display_label_en) }
    it { is_expected.to validate_presence_of(:display_label_ru) }
    it { is_expected.to validate_uniqueness_of(:source) }

    it "validates priority is non-negative" do
      record = build(:attribution_source, priority: -1)
      expect(record).not_to be_valid
    end
  end

  describe "scopes" do
    describe ".pipeline" do
      it "returns enabled sources ordered by priority asc" do
        unattr = create(:attribution_source, :unattributed)
        raid = create(:attribution_source, :raid_organic)
        _disabled = create(:attribution_source, :disabled, priority: 5)

        expect(described_class.pipeline).to eq([ raid, unattr ])
      end
    end
  end

  describe "#adapter_class" do
    it "constantizes adapter_class_name to actual class" do
      stub_const("Trends::Attribution::RaidAdapter", Class.new)
      source = build(:attribution_source, adapter_class_name: "Trends::Attribution::RaidAdapter")
      expect(source.adapter_class).to eq(Trends::Attribution::RaidAdapter)
    end

    it "raises AdapterNotFound when class doesn't exist" do
      source = build(:attribution_source, adapter_class_name: "Nonexistent::Adapter")
      expect { source.adapter_class }.to raise_error(described_class::AdapterNotFound, /not found/)
    end
  end
end
