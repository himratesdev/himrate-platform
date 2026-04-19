# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnomalyAttribution do
  # Ensure known sources available для source inclusion validation.
  before do
    Rails.cache.clear
    create(:attribution_source, :raid_organic)
    create(:attribution_source, source: "platform_cleanup", adapter_class_name: "Trends::Attribution::PlatformCleanupAdapter")
    create(:attribution_source, :unattributed)
  end

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

    describe "source_is_known validator" do
      it "rejects unknown source (typo protection)" do
        record = build(:anomaly_attribution, source: "raid_bbot")
        expect(record).not_to be_valid
        expect(record.errors[:source]).to include(/is not a known attribution source/)
      end

      it "accepts canonical source from AttributionSource table" do
        expect(build(:anomaly_attribution, source: "raid_organic")).to be_valid
      end

      it "accepts disabled sources (могут existing records ссылаться на disabled source)" do
        create(:attribution_source, source: "igdb_release", enabled: false,
          adapter_class_name: "Trends::Attribution::IgdbAdapter")
        expect(build(:anomaly_attribution, source: "igdb_release")).to be_valid
      end
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
      source_config = AttributionSource.find_by(source: "raid_organic")
      attribution = create(:anomaly_attribution, source: "raid_organic")
      expect(attribution.source_config).to eq(source_config)
    end

    it "returns nil when source string has no config" do
      # Валидатор блокирует unknown source через validation,
      # но find_by возвращает nil если config был удалён между save и lookup.
      attribution = create(:anomaly_attribution, source: "raid_organic")
      AttributionSource.where(source: "raid_organic").delete_all
      Rails.cache.clear
      expect(attribution.source_config).to be_nil
    end
  end
end
