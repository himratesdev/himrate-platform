# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnomalyAttribution do
  describe "associations" do
    it { is_expected.to belong_to(:anomaly) }
  end

  describe "validations" do
    subject { build(:anomaly_attribution) }

    it { is_expected.to be_valid }
    it { is_expected.to validate_presence_of(:source) }
    it { is_expected.to validate_presence_of(:attributed_at) }

    it "validates confidence in 0..1" do
      expect(build(:anomaly_attribution, confidence: 0.5)).to be_valid
      expect(build(:anomaly_attribution, confidence: 1.5)).not_to be_valid
      expect(build(:anomaly_attribution, confidence: -0.1)).not_to be_valid
    end

    it "validates uniqueness of source scoped to anomaly" do
      existing = create(:anomaly_attribution)
      dup = build(:anomaly_attribution, anomaly: existing.anomaly, source: existing.source)
      expect(dup).not_to be_valid
    end

    it "allows different sources for same anomaly" do
      existing = create(:anomaly_attribution, source: "raid_organic")
      another = build(:anomaly_attribution, anomaly: existing.anomaly, source: "platform_cleanup")
      expect(another).to be_valid
    end
  end

  describe "scopes" do
    describe ".attributed" do
      it "excludes unattributed source" do
        attributed = create(:anomaly_attribution, source: "raid_organic")
        _unattr = create(:anomaly_attribution, source: "unattributed")
        expect(described_class.attributed).to contain_exactly(attributed)
      end
    end

    describe ".by_confidence" do
      it "orders by confidence desc" do
        low = create(:anomaly_attribution, confidence: 0.3)
        high = create(:anomaly_attribution, confidence: 0.95)
        mid = create(:anomaly_attribution, confidence: 0.6)
        expect(described_class.by_confidence).to eq([ high, mid, low ])
      end
    end
  end

  describe "#source_config" do
    it "looks up canonical AttributionSource by source string" do
      source_config = create(:attribution_source, :raid_organic)
      attribution = create(:anomaly_attribution, source: "raid_organic")
      expect(attribution.source_config).to eq(source_config)
    end

    it "returns nil when source string has no config" do
      attribution = create(:anomaly_attribution, source: "orphan_source")
      expect(attribution.source_config).to be_nil
    end
  end
end
