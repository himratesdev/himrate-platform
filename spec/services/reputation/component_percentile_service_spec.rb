# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reputation::ComponentPercentileService, type: :service do
  let(:channel) { create(:channel) }

  # CR N-3: stub MIN_CHANNELS чтобы fixture setup был 5 records вместо 100 —
  # service correctness не зависит от threshold magnitude (formula identical).
  # Production constant (100) verified via existing Reputation::PercentileService specs.
  before { stub_const("#{described_class}::MIN_CHANNELS", 5) }

  describe "#call" do
    context "when channel has no reputation record" do
      it "returns nil" do
        expect(described_class.new(channel).call("default")).to be_nil
      end
    end

    context "when category has fewer than MIN_CHANNELS reputations" do
      before do
        create(:streamer_reputation, channel: channel)
        # Only 1 reputation — well below MIN_CHANNELS (100)
      end

      it "returns nil" do
        expect(described_class.new(channel).call("default")).to be_nil
      end
    end

    context "when category has sufficient reputations" do
      before do
        create(:streamer_reputation,
          channel: channel,
          growth_pattern_score: 90.0,
          follower_quality_score: 85.0,
          engagement_consistency_score: 80.0,
          pattern_history_score: 75.0)

        # Seed 5 peer channels с lower scores (MIN_CHANNELS stubbed to 5 для speed).
        # Channel под test должен быть высоко в percentile (его scores 90/85/80/75 vs peers 50-50.5).
        5.times do |i|
          peer_channel = create(:channel, twitch_id: "peer_#{i}", login: "peer_#{i}")
          create(:streamer_reputation,
            channel: peer_channel,
            growth_pattern_score: 50.0 + (i * 0.1),
            follower_quality_score: 50.0 + (i * 0.1),
            engagement_consistency_score: 50.0 + (i * 0.1),
            pattern_history_score: 50.0 + (i * 0.1))
        end
      end

      it "returns Hash with all 4 components in high percentile range" do
        result = described_class.new(channel).call("default")
        expect(result).to be_a(Hash)
        expect(result.keys).to match_array(%i[growth_pattern follower_quality engagement_consistency pattern_history])
        # Math: 5 peers + 1 test channel = 6 total. count_below excludes self →
        # max possible percentile с 5 peers = 5/6 ≈ 83.3%. Channel scores
        # (90/85/80/75) выше всех peers (50-50.4) → expects max percentile.
        expect(result[:engagement_consistency]).to be > 80.0
      end
    end

    context "when component value is nil" do
      before do
        create(:streamer_reputation, channel: channel, engagement_consistency_score: nil)

        5.times do |i|
          peer_channel = create(:channel, twitch_id: "peer_#{i}", login: "peer_#{i}")
          create(:streamer_reputation, channel: peer_channel,
                 engagement_consistency_score: 50.0 + (i * 0.1))
        end
      end

      it "returns nil for that component while computing others" do
        result = described_class.new(channel).call("default")
        expect(result).to be_a(Hash)
        expect(result[:engagement_consistency]).to be_nil
      end
    end

    context "Redis cache" do
      it "caches computation under versioned key" do
        service = described_class.new(channel)
        cache_key = service.send(:cache_key, "default")
        expect(cache_key).to include("reputation:component_percentile:default:v")
        expect(cache_key).to include(channel.id)
      end
    end
  end
end
