# frozen_string_literal: true

require "rails_helper"

RSpec.describe Brand::AudienceOverlapService, type: :service do
  # A = {alice, bob, eve}, B = {alice, carol}, C = {carol, dave}
  # overlaps: A∩B={alice}, A∩C={}, B∩C={carol}
  let!(:a) { create(:channel, login: "aaa") }
  let!(:b) { create(:channel, login: "bbb") }
  let!(:c) { create(:channel, login: "ccc") }

  before do
    { a => %w[alice bob eve], b => %w[alice carol], c => %w[carol dave] }.each do |channel, users|
      users.each { |u| create(:cross_channel_presence, channel: channel, username: u) }
    end
  end

  it "rejects fewer than 2 channels" do
    expect(described_class.new(%w[aaa]).call.error).to eq("CHANNELS_REQUIRED")
  end

  it "rejects an unknown login" do
    expect(described_class.new(%w[aaa ghost]).call.error).to eq("CHANNEL_NOT_FOUND")
  end

  describe "overlap math for 3 channels" do
    subject(:payload) { described_class.new(%w[aaa bbb ccc]).call.payload }

    it "computes unique and total reach" do
      expect(payload[:unique_reach]).to eq(5)   # alice bob eve carol dave
      expect(payload[:total_reach]).to eq(7)    # 3 + 2 + 2
    end

    it "computes pairwise overlap with strength" do
      # Match a pair regardless of (a, b) orientation so the assertion never depends on column order.
      pair = ->(x, y) { payload[:pairwise].find { |p| [ p[:a], p[:b] ].sort == [ x, y ].sort } }
      ab = pair.call("aaa", "bbb")
      ac = pair.call("aaa", "ccc")
      expect(ab[:shared]).to eq(1)               # alice
      expect(ab[:percent]).to eq(50.0)           # 1 / min(3,2)
      expect(ab[:strength]).to eq("strong")
      expect(ac[:shared]).to eq(0)
      expect(ac[:strength]).to eq("weak")
    end

    it "returns channels and pairwise in the REQUESTED order (deterministic, not DB order)" do
      expect(payload[:channels].map { |c| c[:login] }).to eq(%w[aaa bbb ccc])
      # combination order over the requested channels → aaa×bbb, aaa×ccc, bbb×ccc
      expect(payload[:pairwise].map { |p| [ p[:a], p[:b] ] }).to eq([ %w[aaa bbb], %w[aaa ccc], %w[bbb ccc] ])
    end

    it "composition sums to unique reach" do
      total = payload[:composition].sum { |seg| seg[:count] }
      expect(total).to eq(payload[:unique_reach])
      shared = payload[:composition].find { |s| s[:segment] == "shared_2plus" }
      expect(shared[:count]).to eq(2)            # alice, carol
    end

    it "labels the chatters-only basis" do
      expect(payload[:audience_basis]).to eq("chat_presence")
    end
  end
end
