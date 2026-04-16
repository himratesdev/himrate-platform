# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::Classifier do
  before do
    # Seed 5 tiers (required since Classifier reads from DB)
    HealthScoreTier.delete_all
    load Rails.root.join("db/seeds/health_score.rb")
    HealthScoreSeeds.seed_tiers
  end

  describe ".classification" do
    it "returns 'excellent' for score >= 80" do
      expect(described_class.classification(80)).to eq("excellent")
      expect(described_class.classification(100)).to eq("excellent")
    end

    it "returns 'good' for 60..79" do
      expect(described_class.classification(60)).to eq("good")
      expect(described_class.classification(79)).to eq("good")
    end

    it "returns 'average' for 40..59" do
      expect(described_class.classification(40)).to eq("average")
      expect(described_class.classification(59)).to eq("average")
    end

    it "returns 'below_average' for 20..39" do
      expect(described_class.classification(20)).to eq("below_average")
      expect(described_class.classification(39)).to eq("below_average")
    end

    it "returns 'poor' for 0..19" do
      expect(described_class.classification(0)).to eq("poor")
      expect(described_class.classification(19)).to eq("poor")
    end

    it "handles boundary transitions precisely" do
      expect(described_class.classification(79)).to eq("good")
      expect(described_class.classification(80)).to eq("excellent")
      expect(described_class.classification(59)).to eq("average")
      expect(described_class.classification(60)).to eq("good")
    end

    it "returns nil for nil score" do
      expect(described_class.classification(nil)).to be_nil
    end
  end

  describe ".for" do
    it "returns full tier hash" do
      tier = described_class.for(72)
      expect(tier[:key]).to eq("good")
      expect(tier[:color]).to eq("light_green")
      expect(tier[:bg_hex]).to eq("#F1F8E9")
      expect(tier[:text_hex]).to eq("#558B2F")
      expect(tier[:i18n_key]).to eq("hs.label.good")
    end
  end
end
