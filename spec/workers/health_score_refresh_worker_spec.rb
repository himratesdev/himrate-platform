# frozen_string_literal: true

require "rails_helper"

RSpec.describe HealthScoreRefreshWorker do
  let(:channel) { create(:channel) }

  before do
    # TASK-038: Seed DB-driven config (categories, tiers, weights)
    load Rails.root.join("db/seeds/health_score.rb") unless HealthScoreCategory.exists?
    HealthScoreSeeds.seed_categories
    HealthScoreSeeds.seed_tiers
    { ti: 0.30, stability: 0.20, engagement: 0.20, growth: 0.15, consistency: 0.15 }.each do |comp, value|
      cfg = SignalConfiguration.find_or_initialize_by(
        signal_type: "health_score", category: "default", param_name: "weight_#{comp}"
      )
      cfg.param_value = value
      cfg.save!
    end
  end

  describe "#perform" do
    context "with completed streams" do
      before do
        10.times do |i|
          stream = create(:stream, channel: channel,
            started_at: (30 - i).days.ago,
            ended_at: (30 - i).days.ago + 3.hours,
            peak_ccv: 5000, avg_ccv: 4000)

          create(:trust_index_history,
            channel: channel, stream: stream,
            trust_index_score: 70.0 + i,
            erv_percent: 70.0 + i,
            ccv: 5000, confidence: 0.85,
            classification: "needs_review",
            cold_start_status: "full",
            signal_breakdown: {},
            calculated_at: stream.ended_at)
        end
      end

      it "creates health_score record" do
        expect { described_class.new.perform(channel.id) }
          .to change(HealthScore, :count).by(1)

        hs = HealthScore.last
        expect(hs.channel_id).to eq(channel.id)
        expect(hs.health_score).to be_between(0.0, 100.0)
        expect(hs.confidence_level).to eq("full")
        expect(hs.ti_component).to be_present
        expect(hs.calculated_at).to be_present
      end

      it "clamps health_score to 0-100" do
        described_class.new.perform(channel.id)

        hs = HealthScore.last
        expect(hs.health_score).to be >= 0.0
        expect(hs.health_score).to be <= 100.0
      end
    end

    context "with few streams" do
      before do
        stream = create(:stream, channel: channel, started_at: 2.days.ago, ended_at: 1.day.ago)
        create(:trust_index_history,
          channel: channel, stream: stream,
          trust_index_score: 72.0, erv_percent: 72.0, ccv: 5000,
          confidence: 0.85, classification: "needs_review", cold_start_status: "provisional_low",
          signal_breakdown: {}, calculated_at: 1.day.ago)
      end

      it "sets confidence provisional_low for 1 stream" do
        described_class.new.perform(channel.id)

        expect(HealthScore.last.confidence_level).to eq("insufficient")
      end

      it "returns nil for components requiring >= 7 streams" do
        described_class.new.perform(channel.id)

        hs = HealthScore.last
        expect(hs.stability_component).to be_nil
        expect(hs.growth_component).to be_nil
        expect(hs.consistency_component).to be_nil
      end
    end

    context "with 0 streams" do
      it "does not create health_score" do
        expect { described_class.new.perform(channel.id) }
          .not_to change(HealthScore, :count)
      end
    end

    context "with non-existent channel" do
      it "returns without error" do
        expect { described_class.new.perform("non-existent") }.not_to raise_error
      end
    end
  end
end
