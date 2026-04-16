# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::TierChangeDetector do
  let(:channel) { create(:channel) }
  subject(:detector) { described_class.new }

  def create_hs(score, classification, calculated_at)
    HealthScore.create!(
      channel_id: channel.id,
      health_score: score,
      hs_classification: classification,
      confidence_level: "full",
      calculated_at: calculated_at
    )
  end

  describe "#call" do
    it "returns nil for first HS record (no previous)" do
      hs = create_hs(72, "good", Time.current)
      expect(detector.call(channel: channel, new_hs_record: hs)).to be_nil
      expect(HsTierChangeEvent.count).to eq(0)
    end

    it "creates event on cross-tier change up" do
      create_hs(58, "average", 2.days.ago)
      new_hs = create_hs(62, "good", Time.current)

      event = detector.call(channel: channel, new_hs_record: new_hs)
      expect(event).to be_present
      expect(event.from_tier).to eq("average")
      expect(event.to_tier).to eq("good")
      expect(event.event_type).to eq("tier_change")
      expect(event.metadata["delta"]).to eq(4.0)
    end

    it "creates event on cross-tier change down" do
      create_hs(82, "excellent", 2.days.ago)
      new_hs = create_hs(75, "good", Time.current)

      event = detector.call(channel: channel, new_hs_record: new_hs)
      expect(event.from_tier).to eq("excellent")
      expect(event.to_tier).to eq("good")
    end

    it "returns nil when classification unchanged" do
      create_hs(72, "good", 2.days.ago)
      new_hs = create_hs(78, "good", Time.current)

      expect(detector.call(channel: channel, new_hs_record: new_hs)).to be_nil
      expect(HsTierChangeEvent.count).to eq(0)
    end
  end
end
