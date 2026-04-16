# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::Components do
  let(:channel) { create(:channel) }
  subject(:components) { described_class.new(channel) }

  describe "#growth_component" do
    it "computes log₁₀ growth for Δ=1000 followers ≈ 60.05" do
      cutoff = 30.days.ago

      # 7 streams to pass MIN_STREAMS_FULL gate
      7.times do |i|
        create(:stream, channel: channel,
          started_at: (25 - i).days.ago, ended_at: (25 - i).days.ago + 1.hour)
      end

      FollowerSnapshot.create!(channel: channel, followers_count: 1000, timestamp: 25.days.ago)
      FollowerSnapshot.create!(channel: channel, followers_count: 2000, timestamp: 1.day.ago)

      score = components.growth_component(cutoff, 7)
      # log10(1001) × 20 ≈ 60.05
      expect(score).to be_within(0.5).of(60.05)
    end

    it "returns 0 when Δfollowers ≤ 0" do
      cutoff = 30.days.ago
      7.times do |i|
        create(:stream, channel: channel,
          started_at: (25 - i).days.ago, ended_at: (25 - i).days.ago + 1.hour)
      end

      FollowerSnapshot.create!(channel: channel, followers_count: 1000, timestamp: 25.days.ago)
      FollowerSnapshot.create!(channel: channel, followers_count: 900, timestamp: 1.day.ago)

      expect(components.growth_component(cutoff, 7)).to eq(0.0)
    end

    it "returns nil for < 7 streams" do
      cutoff = 30.days.ago
      create(:stream, channel: channel, started_at: 5.days.ago, ended_at: 4.days.ago)
      expect(components.growth_component(cutoff, 1)).to be_nil
    end
  end

  describe "#consistency_component" do
    it "computes (stream_days/30)×100 correctly (20 days → 66.67)" do
      cutoff = 30.days.ago
      20.times do |i|
        create(:stream, channel: channel,
          started_at: (20 - i).days.ago, ended_at: (20 - i).days.ago + 1.hour)
      end

      score = components.consistency_component(cutoff, 20)
      expect(score).to be_within(0.5).of(66.67)
    end
  end

  describe "#stability_component (CCV-based, not TI)" do
    it "computes 100×(1-CV(avg_ccv))" do
      cutoff = 30.days.ago
      # avg_ccv values: 100, 150, 200, 250, 300, 350, 400 → mean=250, stddev≈108
      # CV ≈ 108/250 ≈ 0.43 → Stability ≈ 100*(1-0.43) = 57
      [ 100, 150, 200, 250, 300, 350, 400 ].each_with_index do |ccv, i|
        create(:stream, channel: channel,
          started_at: (25 - i).days.ago, ended_at: (25 - i).days.ago + 1.hour,
          avg_ccv: ccv, peak_ccv: ccv)
      end

      score = components.stability_component(cutoff, 7)
      expect(score).to be_within(15).of(57) # loose due to sample STDDEV formula variance
    end

    it "returns nil for < 7 streams" do
      expect(components.stability_component(30.days.ago, 1)).to be_nil
    end
  end
end
