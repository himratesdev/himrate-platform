# frozen_string_literal: true

require "rails_helper"

RSpec.describe PersonalAnalytics::Api::CommunitiesService do
  let(:user) { create(:user) }

  it "returns empty communities when there is no chat activity" do
    expect(described_class.new(user: user, window: "30d").call[:data][:communities]).to eq([])
  end

  it "aggregates per-channel message_count, activity_level and top_emotes across the window" do
    create(:pva_chat_activity, user: user, twitch_channel_id: "555", twitch_login: "xqc",
      date: Date.current, message_count: 600, emote_counts: { "Kappa" => 10, "LUL" => 5 })
    create(:pva_chat_activity, user: user, twitch_channel_id: "555", twitch_login: "xqc",
      date: Date.current - 1, message_count: 50, emote_counts: { "Kappa" => 3 })

    community = described_class.new(user: user, window: "30d").call[:data][:communities].first

    expect(community[:message_count]).to eq(650)
    expect(community[:activity_level]).to eq("high") # >= 500
    expect(community[:top_emotes].first).to eq(emote: "Kappa", count: 13)
  end

  it "raises InvalidWindow for an unknown window" do
    expect { described_class.new(user: user, window: "bogus") }.to raise_error(described_class::InvalidWindow)
  end
end
