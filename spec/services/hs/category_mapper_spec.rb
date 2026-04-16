# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::CategoryMapper do
  before do
    HealthScoreCategoryAlias.delete_all
    HealthScoreCategory.delete_all
    load Rails.root.join("db/seeds/health_score.rb")
    HealthScoreSeeds.seed_categories
    described_class.reset!
  end

  describe ".map" do
    it "matches exact alias" do
      expect(described_class.map("Just Chatting")).to eq("just_chatting")
    end

    it "matches alias case-insensitive" do
      expect(described_class.map("just chatting")).to eq("just_chatting")
      expect(described_class.map("VALORANT")).to eq("valorant")
    end

    it "matches variant aliases" do
      expect(described_class.map("GTA V")).to eq("grand_theft_auto_v")
      expect(described_class.map("CS2")).to eq("counter_strike_2")
      expect(described_class.map("CSGO")).to eq("counter_strike_2")
    end

    it "matches IRL umbrella categories" do
      expect(described_class.map("Travel & Outdoors")).to eq("irl")
      expect(described_class.map("Food & Drink")).to eq("irl")
    end

    it "falls back to default for unknown" do
      expect(described_class.map("Unknown Game XYZ")).to eq("default")
    end

    it "falls back to default for blank input" do
      expect(described_class.map("")).to eq("default")
      expect(described_class.map(nil)).to eq("default")
    end
  end

  describe ".normalize" do
    it "normalizes common game names" do
      expect(described_class.normalize("Grand Theft Auto V")).to eq("grand_theft_auto_v")
      expect(described_class.normalize("Counter-Strike: Global Offensive")).to eq("counter_strike_global_offensive")
    end

    it "squashes multiple spaces" do
      expect(described_class.normalize("Just   Chatting")).to eq("just_chatting")
    end

    it "strips special chars" do
      expect(described_class.normalize("Game! Name?")).to eq("game_name")
    end
  end
end
