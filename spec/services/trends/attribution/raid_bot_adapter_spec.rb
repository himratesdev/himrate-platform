# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::RaidBotAdapter do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly) { create(:anomaly, stream: stream) }

  describe ".call" do
    context "no RaidAttribution" do
      it "returns nil" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "bot raid exists" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: true,
                                  bot_score: 0.85, raid_viewers_count: 100, timestamp: 1.hour.ago)
      end

      it "returns raid_bot с bot_score as confidence" do
        result = described_class.call(anomaly)
        expect(result[:source]).to eq("raid_bot")
        expect(result[:confidence]).to eq(0.85)
        expect(result[:raw_source_data][:bot_score]).to eq(0.85)
      end
    end

    context "only organic raid exists (no bot)" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: false)
      end

      it "returns nil (1:1 mapping — bot filter excludes organic)" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "bot_score nil" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: true, bot_score: nil)
      end

      it "falls back на 0.8 confidence" do
        result = described_class.call(anomaly)
        expect(result[:confidence]).to eq(0.8)
      end
    end

    context "multiple bot raids" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: true,
                                  bot_score: 0.5, timestamp: 3.hours.ago)
        create(:raid_attribution, stream: stream, is_bot_raid: true,
                                  bot_score: 0.95, timestamp: 1.hour.ago)
      end

      it "picks latest по timestamp DESC" do
        result = described_class.call(anomaly)
        expect(result[:confidence]).to eq(0.95)
      end
    end
  end
end
