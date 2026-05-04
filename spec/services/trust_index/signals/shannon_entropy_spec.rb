# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::ShannonEntropy do
  describe ".compute" do
    it "returns 0.0 для empty input (no information)" do
      expect(described_class.compute([])).to eq(0.0)
    end

    it "returns 0.0 для single category (no choice = no entropy)" do
      expect(described_class.compute([ 100 ])).to eq(0.0)
    end

    it "returns log2(N) для N equally distributed categories" do
      expect(described_class.compute([ 10, 10 ])).to be_within(0.01).of(1.0)
      expect(described_class.compute([ 10, 10, 10, 10 ])).to be_within(0.01).of(2.0)
      expect(described_class.compute(Array.new(8, 5))).to be_within(0.01).of(3.0)
    end

    it "returns less than log2(N) для skewed distribution (less entropy)" do
      uniform = described_class.compute([ 10, 10, 10, 10 ])
      skewed = described_class.compute([ 100, 1, 1, 1 ])
      expect(skewed).to be < uniform
    end

    it "handles zero counts gracefully (treats as no information)" do
      expect(described_class.compute([ 0, 0 ])).to eq(0.0)
    end

    it "handles mixed zero and non-zero counts" do
      expect(described_class.compute([ 0, 10 ])).to eq(0.0)
      expect(described_class.compute([ 0, 10, 10 ])).to be_within(0.01).of(1.0)
    end

    it "templated chat (1 dominant user) returns very low entropy (chat_entropy_drop alert range)" do
      counts = [ 95, 1, 1, 1, 1, 1 ]
      entropy = described_class.compute(counts)
      expect(entropy).to be < 2.0  # threshold per BR-010 for chat_entropy_drop alert
    end

    it "diverse healthy chat (50 unique users equally) returns ~log2(50) bits" do
      counts = Array.new(50, 1)
      entropy = described_class.compute(counts)
      expect(entropy).to be_within(0.01).of(Math.log2(50))
      expect(entropy).to be > 5.0  # well above 2.0 threshold
    end
  end
end
