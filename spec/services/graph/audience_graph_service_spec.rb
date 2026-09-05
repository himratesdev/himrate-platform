# frozen_string_literal: true

require "rails_helper"

RSpec.describe Graph::AudienceGraphService do
  let(:ch_a) { create(:channel, login: "alpha") }
  let(:ch_b) { create(:channel, login: "beta") }
  let(:ch_c) { create(:channel, login: "gamma") }

  def presence(channel, usernames)
    usernames.each do |u|
      CrossChannelPresence.create!(channel: channel, username: u,
                                   first_seen_at: 1.day.ago, last_seen_at: 1.hour.ago,
                                   message_count: 3)
    end
  end

  before { Rails.cache.delete("graph:audience:full") }

  it "builds nodes with audience/band and edges with shared counts + overlap share" do
    shared = (1..6).map { |i| "user#{i}" }
    presence(ch_a, shared + %w[only_a1 only_a2])
    presence(ch_b, shared)
    create(:trust_index_history, channel: ch_a, band_color: "green")

    result = described_class.new.build

    expect(result[:basis]).to eq("chat_presence")
    a_node = result[:nodes].find { |n| n[:login] == "alpha" }
    expect(a_node[:audience]).to eq(8)
    expect(a_node[:band]).to eq("green")
    edge = result[:edges].first
    expect(edge[:shared]).to eq(6)
    expect(edge[:share]).to eq(1.0) # 6 shared / min(8, 6)
  end

  it "drops pairs under MIN_SHARED and excludes power users from edges" do
    few = %w[u1 u2] # below MIN_SHARED=5
    presence(ch_a, few)
    presence(ch_b, few)

    expect(described_class.new.build[:edges]).to be_empty
  end

  it "focus mode returns the ego graph and CHANNEL_NOT_FOUND for unknown logins" do
    shared = (1..6).map { |i| "user#{i}" }
    presence(ch_a, shared)
    presence(ch_b, shared)
    presence(ch_c, %w[loner1 loner2])

    result = described_class.new(focus: "alpha").build
    expect(result[:focus]).to eq("alpha")
    expect(result[:nodes].map { |n| n[:login] }).to contain_exactly("alpha", "beta")

    expect(described_class.new(focus: "nope").build[:error]).to eq("CHANNEL_NOT_FOUND")
  end
end
