# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Features::ViewerSignals do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel, avg_ccv: 500, peak_ccv: 800) }
  let(:viewer) { described_class.new(stream) }

  describe "BOT_TIERS" do
    it "exposes commercial bot package levels per BFT 15_ML-Pipeline §3.2" do
      expect(described_class::BOT_TIERS).to eq([ 200, 500, 1000, 1500 ])
    end
  end

  describe "#call (insufficient data)" do
    it "returns all-nil hash for stream with no CCV snapshots" do
      result = viewer.call
      expect(result).to eq(
        chatter_to_ccv_ratio: nil,
        peak_to_average_ccv_ratio: nil,
        ccv_coefficient_of_variation: nil,
        ccv_tier_stickiness: nil
      )
    end

    it "populates insufficient_data_reasons for each missing feature" do
      viewer.call
      expect(viewer.insufficient_data_reasons.keys).to match_array(
        %i[chatter_to_ccv_ratio peak_to_average_ccv_ratio ccv_coefficient_of_variation ccv_tier_stickiness]
      )
    end
  end

  describe "#chatter_to_ccv_ratio" do
    it "computes mean(chatters) / mean(ccv) when both populated" do
      create(:ccv_snapshot, stream: stream, ccv_count: 100, timestamp: 5.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 200, timestamp: 4.minutes.ago)
      create(:chatters_snapshot, stream: stream, unique_chatters_count: 30, total_messages_count: 0, timestamp: 5.minutes.ago)
      create(:chatters_snapshot, stream: stream, unique_chatters_count: 60, total_messages_count: 0, timestamp: 4.minutes.ago)

      result = viewer.call
      # mean_chatters = 45, mean_ccv = 150 → ratio = 0.3
      expect(result[:chatter_to_ccv_ratio]).to be_within(0.001).of(0.3)
    end

    it "returns nil when ccv mean is zero" do
      create(:ccv_snapshot, stream: stream, ccv_count: 0, timestamp: 5.minutes.ago)
      create(:chatters_snapshot, stream: stream, unique_chatters_count: 5, total_messages_count: 0, timestamp: 5.minutes.ago)

      result = viewer.call
      expect(result[:chatter_to_ccv_ratio]).to be_nil
      expect(viewer.insufficient_data_reasons[:chatter_to_ccv_ratio]).to eq("zero_mean_ccv")
    end
  end

  describe "#peak_to_average_ccv_ratio" do
    it "computes max(ccv) / mean(ccv) over >=3 snapshots" do
      [ 100, 200, 600 ].each_with_index { |ccv, i| create(:ccv_snapshot, stream: stream, ccv_count: ccv, timestamp: (5 - i).minutes.ago) }

      result = viewer.call
      # mean = 300, peak = 600 → ratio = 2.0
      expect(result[:peak_to_average_ccv_ratio]).to be_within(0.001).of(2.0)
    end

    it "returns nil with <3 snapshots" do
      create(:ccv_snapshot, stream: stream, ccv_count: 100, timestamp: 5.minutes.ago)
      create(:ccv_snapshot, stream: stream, ccv_count: 200, timestamp: 4.minutes.ago)

      result = viewer.call
      expect(result[:peak_to_average_ccv_ratio]).to be_nil
      expect(viewer.insufficient_data_reasons[:peak_to_average_ccv_ratio]).to eq("insufficient_snapshots")
    end
  end

  describe "#ccv_coefficient_of_variation (longitudinal, last 30 channel streams)" do
    it "computes std/mean of avg_ccv across recent completed streams" do
      # Need ≥3 historical streams with avg_ccv. Stream provided already counts.
      stream.update!(ended_at: 1.hour.ago, avg_ccv: 100)
      create(:stream, channel: channel, ended_at: 2.hours.ago, avg_ccv: 200)
      create(:stream, channel: channel, ended_at: 3.hours.ago, avg_ccv: 300)

      result = viewer.call
      # mean = 200, variance = ((100-200)² + (200-200)² + (300-200)²) / 3 = 6666.67
      # std ≈ 81.65, cv ≈ 0.4082
      expect(result[:ccv_coefficient_of_variation]).to be_within(0.01).of(0.4082)
    end

    it "returns nil with <3 historical streams" do
      stream.update!(ended_at: 1.hour.ago, avg_ccv: 500)

      result = viewer.call
      expect(result[:ccv_coefficient_of_variation]).to be_nil
      expect(viewer.insufficient_data_reasons[:ccv_coefficient_of_variation]).to eq("insufficient_history")
    end
  end

  describe "#ccv_tier_stickiness" do
    it "scores 1.0 when mean CCV exactly equals a bot tier" do
      [ 500, 500, 500 ].each_with_index { |ccv, i| create(:ccv_snapshot, stream: stream, ccv_count: ccv, timestamp: (5 - i).minutes.ago) }

      result = viewer.call
      expect(result[:ccv_tier_stickiness]).to be_within(0.001).of(1.0)
    end

    it "scores 0.0 when mean CCV is beyond ±50% of any tier" do
      # Mean = 3000 — between 1500 (nearest, |3000-1500|=1500) and well beyond ±50%
      # of 1500 = 750. Distance 1500 > half_band 750 → 0.0.
      [ 3000, 3000, 3000 ].each_with_index { |ccv, i| create(:ccv_snapshot, stream: stream, ccv_count: ccv, timestamp: (5 - i).minutes.ago) }

      result = viewer.call
      expect(result[:ccv_tier_stickiness]).to eq(0.0)
    end

    it "interpolates linearly within ±50% band around tier" do
      # Mean = 600. Nearest tier = 500. half_band = 250. dist = 100. proximity = 1 - 100/250 = 0.6.
      [ 600, 600, 600 ].each_with_index { |ccv, i| create(:ccv_snapshot, stream: stream, ccv_count: ccv, timestamp: (5 - i).minutes.ago) }

      result = viewer.call
      expect(result[:ccv_tier_stickiness]).to be_within(0.001).of(0.6)
    end

    it "returns nil with <3 snapshots" do
      create(:ccv_snapshot, stream: stream, ccv_count: 500, timestamp: 5.minutes.ago)

      result = viewer.call
      expect(result[:ccv_tier_stickiness]).to be_nil
      expect(viewer.insufficient_data_reasons[:ccv_tier_stickiness]).to eq("insufficient_snapshots")
    end
  end
end
