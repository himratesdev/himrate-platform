# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::RaidAdapter do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly) { create(:anomaly, stream: stream) }

  describe ".call" do
    context "no RaidAttribution" do
      it "returns nil" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "bot raid" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: true,
                                  bot_score: 0.85, raid_viewers_count: 100, timestamp: 1.hour.ago)
      end

      it "returns raid_bot с bot_score как confidence" do
        result = described_class.call(anomaly)
        expect(result[:source]).to eq("raid_bot")
        expect(result[:confidence]).to eq(0.85)
        expect(result[:raw_source_data][:is_bot_raid]).to be true
        expect(result[:raw_source_data][:raid_viewers_count]).to eq(100)
      end
    end

    context "organic raid" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: false,
                                  raid_viewers_count: 50, timestamp: 1.hour.ago)
      end

      it "returns raid_organic с default 0.8 confidence" do
        result = described_class.call(anomaly)
        expect(result[:source]).to eq("raid_organic")
        expect(result[:confidence]).to eq(0.8)
      end
    end

    context "multiple raids" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: false, timestamp: 3.hours.ago)
        create(:raid_attribution, stream: stream, is_bot_raid: true, bot_score: 0.95, timestamp: 1.hour.ago)
      end

      it "picks latest raid по timestamp DESC" do
        result = described_class.call(anomaly)
        expect(result[:source]).to eq("raid_bot")
        expect(result[:confidence]).to eq(0.95)
      end
    end
  end
end
