# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::RaidOrganicAdapter do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly) { create(:anomaly, stream: stream) }

  describe ".call" do
    context "no RaidAttribution" do
      it "returns nil" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "organic raid exists" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: false,
                                  raid_viewers_count: 50, timestamp: 1.hour.ago)
      end

      it "returns raid_organic с 0.8 default confidence" do
        result = described_class.call(anomaly)
        expect(result[:source]).to eq("raid_organic")
        expect(result[:confidence]).to eq(0.8)
        expect(result[:raw_source_data][:raid_viewers_count]).to eq(50)
      end
    end

    context "only bot raid exists (no organic)" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: true, bot_score: 0.9)
      end

      it "returns nil (1:1 mapping — organic filter excludes bot raid)" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "multiple organic raids" do
      before do
        create(:raid_attribution, stream: stream, is_bot_raid: false,
                                  raid_viewers_count: 30, timestamp: 3.hours.ago)
        create(:raid_attribution, stream: stream, is_bot_raid: false,
                                  raid_viewers_count: 70, timestamp: 1.hour.ago)
      end

      it "picks latest по timestamp DESC" do
        result = described_class.call(anomaly)
        expect(result[:raw_source_data][:raid_viewers_count]).to eq(70)
      end
    end
  end
end
