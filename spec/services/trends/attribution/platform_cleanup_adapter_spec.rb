# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Attribution::PlatformCleanupAdapter do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly_time) { Time.current }
  let(:anomaly) { create(:anomaly, stream: stream, timestamp: anomaly_time) }

  # platform_cleanup_* configs — mirror migration 20260420100003.
  before do
    {
      "cleanup_drop_threshold" => 0.05,
      "cleanup_confidence_normalizer" => 0.10
    }.each do |param, value|
      SignalConfiguration.find_or_create_by!(
        signal_type: "trust_index", category: "platform_cleanup", param_name: param
      ) { |c| c.param_value = value }
    end
  end

  describe ".call" do
    context "no FollowerSnapshots" do
      it "returns nil" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "drop < threshold (normal churn)" do
      before do
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 2.hours, followers_count: 10_000)
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 1.hour, followers_count: 9_950) # 0.5% drop
      end

      it "returns nil (below 5% threshold)" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "drop >= threshold (platform cleanup event)" do
      before do
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 2.hours, followers_count: 10_000)
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 1.hour, followers_count: 9_000) # 10% drop
      end

      it "returns platform_cleanup с confidence proportional к drop" do
        result = described_class.call(anomaly)
        expect(result[:source]).to eq("platform_cleanup")
        # drop_fraction = 0.10, confidence_normalizer = 0.10 → confidence = 1.0 (clamped)
        expect(result[:confidence]).to eq(1.0)
        expect(result[:raw_source_data][:delta]).to eq(-1_000)
        expect(result[:raw_source_data][:drop_fraction]).to eq(0.1)
      end
    end

    context "follower increase (no cleanup)" do
      before do
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 2.hours, followers_count: 10_000)
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 1.hour, followers_count: 10_500) # growth
      end

      it "returns nil (positive delta)" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end

    context "previous count is zero" do
      before do
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 2.hours, followers_count: 0)
        create(:follower_snapshot, channel: channel, timestamp: anomaly_time - 1.hour, followers_count: 100)
      end

      it "returns nil (division by zero guard)" do
        expect(described_class.call(anomaly)).to be_nil
      end
    end
  end
end
