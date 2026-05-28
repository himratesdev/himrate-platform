# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::EngagementLogService do
  let(:user) { create(:user) }

  it "returns entries newest-first" do
    create(:pva_engagement_event, user: user, twitch_channel_id: "555", event_type: "cheer", occurred_at: 1.hour.ago)
    create(:pva_engagement_event, user: user, twitch_channel_id: "555", event_type: "follow", occurred_at: 2.hours.ago)

    entries = described_class.new(user: user).call[:data][:entries]

    expect(entries.map { |e| e[:type] }).to eq(%w[cheer follow])
  end

  it "filters by event type" do
    create(:pva_engagement_event, user: user, event_type: "cheer")
    create(:pva_engagement_event, user: user, event_type: "follow")

    entries = described_class.new(user: user, type: "cheer").call[:data][:entries]

    expect(entries.map { |e| e[:type] }).to eq(%w[cheer])
  end

  it "raises InvalidType for an unknown type" do
    expect { described_class.new(user: user, type: "bogus") }.to raise_error(described_class::InvalidType)
  end
end
