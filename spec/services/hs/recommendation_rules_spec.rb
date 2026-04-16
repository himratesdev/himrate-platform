# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::RecommendationRules do
  describe ".evaluate — per-rule coverage" do
    def ctx(overrides = {})
      {
        components: {},
        components_percentile: {},
        ti_drop_pts: nil,
        ti_drop_threshold: 15.0,
        latest_ti: nil,
        followers_delta: 0
      }.merge(overrides)
    end

    it "R-01 fires for engagement percentile 20..39" do
      expect(described_class.evaluate("R-01", ctx(components_percentile: { engagement: 30 }))).to be true
      expect(described_class.evaluate("R-01", ctx(components_percentile: { engagement: 10 }))).to be false
      expect(described_class.evaluate("R-01", ctx(components_percentile: { engagement: 45 }))).to be false
    end

    it "R-02 fires for engagement percentile <20" do
      expect(described_class.evaluate("R-02", ctx(components_percentile: { engagement: 15 }))).to be true
      expect(described_class.evaluate("R-02", ctx(components_percentile: { engagement: 20 }))).to be false
    end

    it "R-03 fires for consistency 30..49" do
      expect(described_class.evaluate("R-03", ctx(components: { consistency: 40 }))).to be true
      expect(described_class.evaluate("R-03", ctx(components: { consistency: 25 }))).to be false
    end

    it "R-04 fires for consistency <30" do
      expect(described_class.evaluate("R-04", ctx(components: { consistency: 20 }))).to be true
      expect(described_class.evaluate("R-04", ctx(components: { consistency: 35 }))).to be false
    end

    it "R-05 fires for stability <50" do
      expect(described_class.evaluate("R-05", ctx(components: { stability: 40 }))).to be true
      expect(described_class.evaluate("R-05", ctx(components: { stability: 60 }))).to be false
    end

    it "R-06 fires for growth <30 with non-negative delta" do
      expect(described_class.evaluate("R-06", ctx(components: { growth: 20 }, followers_delta: 50))).to be true
      expect(described_class.evaluate("R-06", ctx(components: { growth: 20 }, followers_delta: -5))).to be false # R-07 territory
    end

    it "R-07 fires for negative follower delta" do
      expect(described_class.evaluate("R-07", ctx(followers_delta: -10))).to be true
      expect(described_class.evaluate("R-07", ctx(followers_delta: 0))).to be false
    end

    it "R-08 fires when TI drop ≥ threshold (drop = negative delta)" do
      expect(described_class.evaluate("R-08", ctx(ti_drop_pts: -20))).to be true
      expect(described_class.evaluate("R-08", ctx(ti_drop_pts: -10))).to be false
    end

    it "R-09 fires when TI < 50 (penalty active)" do
      expect(described_class.evaluate("R-09", ctx(latest_ti: 45))).to be true
      expect(described_class.evaluate("R-09", ctx(latest_ti: 55))).to be false
    end

    it "R-10 fires when all components > 80" do
      comp = { ti: 85, stability: 85, engagement: 85, growth: 85, consistency: 85 }
      expect(described_class.evaluate("R-10", ctx(components: comp))).to be true

      low = comp.merge(engagement: 70)
      expect(described_class.evaluate("R-10", ctx(components: low))).to be false
    end

    it "returns false for unknown rule_id" do
      expect(described_class.evaluate("R-99", ctx)).to be false
    end
  end
end
