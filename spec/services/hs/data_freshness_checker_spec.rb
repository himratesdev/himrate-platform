# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::DataFreshnessChecker do
  describe ".call" do
    it "returns 'fresh' for <48h" do
      expect(described_class.call(2.hours.ago)).to eq("fresh")
      expect(described_class.call(47.hours.ago)).to eq("fresh")
    end

    it "returns 'stale' for 48h-30d" do
      expect(described_class.call(49.hours.ago)).to eq("stale")
      expect(described_class.call(15.days.ago)).to eq("stale")
      expect(described_class.call(29.days.ago)).to eq("stale")
    end

    it "returns 'very_stale' for >30d" do
      expect(described_class.call(31.days.ago)).to eq("very_stale")
      expect(described_class.call(90.days.ago)).to eq("very_stale")
    end

    it "returns nil for nil input" do
      expect(described_class.call(nil)).to be_nil
    end
  end
end
