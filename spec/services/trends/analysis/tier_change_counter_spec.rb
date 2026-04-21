# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::TierChangeCounter do
  let(:channel) { create(:channel) }
  let(:from) { 30.days.ago }
  let(:to) { Time.current }

  it "returns zero count when no events" do
    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:count]).to eq(0)
    expect(result[:latest]).to be_nil
  end

  it "counts tier_change events in range" do
    create(:hs_tier_change_event, channel: channel, occurred_at: 15.days.ago, event_type: "tier_change", from_tier: "needs_review", to_tier: "trusted")
    create(:hs_tier_change_event, channel: channel, occurred_at: 5.days.ago, event_type: "tier_change", from_tier: "trusted", to_tier: "needs_review")

    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:count]).to eq(2)
    expect(result[:latest][:from_tier]).to eq("trusted")
    expect(result[:latest][:to_tier]).to eq("needs_review")
  end

  it "excludes events outside range" do
    create(:hs_tier_change_event, channel: channel, occurred_at: 60.days.ago)
    result = described_class.call(channel: channel, from: from, to: to)

    expect(result[:count]).to eq(0)
  end

  it "filters by event_types parameter" do
    create(:hs_tier_change_event, channel: channel, occurred_at: 5.days.ago, event_type: "category_change", to_tier: "Fortnite")
    result = described_class.call(channel: channel, from: from, to: to, event_types: %w[category_change])

    expect(result[:count]).to eq(1)
    expect(result[:latest][:event_type]).to eq("category_change")
  end

  it "excludes events for other channels" do
    other = create(:channel)
    create(:hs_tier_change_event, channel: other, occurred_at: 5.days.ago)

    result = described_class.call(channel: channel, from: from, to: to)
    expect(result[:count]).to eq(0)
  end
end
