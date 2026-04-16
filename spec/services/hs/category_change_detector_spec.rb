# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::CategoryChangeDetector do
  let(:channel) { create(:channel) }
  subject(:detector) { described_class.new }

  def create_hs(category, calculated_at)
    HealthScore.create!(
      channel_id: channel.id,
      health_score: 72,
      hs_classification: "good",
      confidence_level: "full",
      category: category,
      calculated_at: calculated_at
    )
  end

  describe "#call" do
    it "returns nil when category nil" do
      hs = create_hs(nil, Time.current)
      expect(detector.call(channel: channel, new_hs_record: hs)).to be_nil
    end

    it "returns nil for first HS with category" do
      hs = create_hs("just_chatting", Time.current)
      expect(detector.call(channel: channel, new_hs_record: hs)).to be_nil
    end

    it "creates category_change event on switch" do
      create_hs("just_chatting", 2.days.ago)
      new_hs = create_hs("valorant", Time.current)

      event = detector.call(channel: channel, new_hs_record: new_hs)
      expect(event).to be_present
      expect(event.event_type).to eq("category_change")
      expect(event.from_tier).to eq("category:just_chatting")
      expect(event.to_tier).to eq("category:valorant")
      expect(event.metadata["new_category"]).to eq("valorant")
    end

    it "returns nil when category unchanged" do
      create_hs("just_chatting", 2.days.ago)
      new_hs = create_hs("just_chatting", Time.current)

      expect(detector.call(channel: channel, new_hs_record: new_hs)).to be_nil
    end
  end
end
