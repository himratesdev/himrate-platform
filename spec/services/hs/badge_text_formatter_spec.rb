# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::BadgeTextFormatter do
  before do
    HealthScoreCategoryAlias.delete_all
    HealthScoreCategory.delete_all
    load Rails.root.join("db/seeds/health_score.rb") unless HealthScoreCategory.exists?
    HealthScoreSeeds.seed_categories
  end

  describe ".call" do
    it "returns nil when percentile nil" do
      expect(described_class.call(percentile: nil, category_key: "just_chatting")).to be_nil
    end

    it "formats 'Top X% in <category>' in English" do
      result = described_class.call(percentile: 28, category_key: "just_chatting", locale: :en)
      expect(result).to eq("Top 72% in Just Chatting")
    end

    it "formats in Russian" do
      result = described_class.call(percentile: 28, category_key: "just_chatting", locale: :ru)
      expect(result).to eq("Топ-72% в Just Chatting")
    end

    it "uses category display_name from DB" do
      result = described_class.call(percentile: 50, category_key: "counter_strike_2", locale: :en)
      expect(result).to include("Counter-Strike 2")
    end

    it "falls back to humanized key for unknown category" do
      result = described_class.call(percentile: 10, category_key: "some_key", locale: :en)
      expect(result).to include("Some key")
    end
  end
end
