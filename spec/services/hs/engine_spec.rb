# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::Engine do
  let(:channel) { create(:channel) }
  subject(:engine) { described_class.new }

  before do
    # Ensure categories + tiers seeded
    load Rails.root.join("db/seeds/health_score.rb") unless HealthScoreCategory.exists?
    HealthScoreSeeds.seed_categories
    HealthScoreSeeds.seed_tiers

    # Seed default weights (required by WeightsLoader — no hardcoded fallback)
    weights = { ti: 0.30, stability: 0.20, engagement: 0.20, growth: 0.15, consistency: 0.15 }
    weights.each do |comp, value|
      config = SignalConfiguration.find_or_initialize_by(
        signal_type: "health_score", category: "default", param_name: "weight_#{comp}"
      )
      config.param_value = value
      config.save!
    end
  end

  describe "#call" do
    context "with 0 streams" do
      it "returns empty result" do
        result = engine.call(channel)
        expect(result[:health_score]).to be_nil
        expect(result[:stream_count]).to eq(0)
      end
    end

    context "with 1-6 streams (provisional)" do
      before do
        3.times do |i|
          stream = create(:stream, channel: channel,
            started_at: (10 - i).days.ago, ended_at: (10 - i).days.ago + 3.hours,
            duration_ms: 10_800_000, avg_ccv: 100, game_name: "Just Chatting")

          create(:trust_index_history,
            channel_id: channel.id, stream_id: stream.id,
            trust_index_score: 70.0, erv_percent: 70.0, ccv: 100, confidence: 0.85,
            classification: "needs_review", cold_start_status: "full",
            signal_breakdown: {}, calculated_at: stream.ended_at)
        end
      end

      it "applies provisional formula" do
        result = engine.call(channel)
        expect(result[:applied_formula]).to eq(:provisional)
        expect(result[:stream_count]).to eq(3)
        expect(result[:confidence_level]).to eq("provisional_low")
        # Provisional with just TI (3 streams < engagement min) → HS = TI ≈ 70
        expect(result[:health_score]).to be_within(10).of(70)
      end
    end
  end
end
