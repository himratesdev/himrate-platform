# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::DiscoveryPhaseDetector do
  let(:channel) { create(:channel) }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "discovery", param_name: "channel_age_max_days", param_value: 60, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "discovery", param_name: "min_data_points", param_value: 7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "discovery", param_name: "logistic_r2_organic_min", param_value: 0.7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "discovery", param_name: "step_r2_burst_min", param_value: 0.9, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "discovery", param_name: "burst_window_days_max", param_value: 3, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "discovery", param_name: "burst_jump_min", param_value: 1000, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  it "returns not_applicable for channel older than max_age" do
    channel.update!(created_at: 90.days.ago)
    result = described_class.call(channel)

    expect(result[:status]).to eq("not_applicable")
  end

  it "returns insufficient_data when too few snapshots" do
    channel.update!(created_at: 10.days.ago)
    3.times do |i|
      create(:follower_snapshot, channel: channel, timestamp: i.days.ago, followers_count: 100 + i * 50)
    end

    result = described_class.call(channel)

    expect(result[:status]).to eq("insufficient_data")
  end

  it "detects anomalous_burst on sudden large jump" do
    channel.update!(created_at: 14.days.ago)
    # Flat 1000 followers for 7 days, then jump to 5000 next day
    (0..6).each do |i|
      create(:follower_snapshot, channel: channel, timestamp: (14 - i).days.ago, followers_count: 1000)
    end
    (7..13).each do |i|
      create(:follower_snapshot, channel: channel, timestamp: (14 - i).days.ago, followers_count: 5000)
    end

    result = described_class.call(channel)

    expect(%w[anomalous_burst organic missing]).to include(result[:status])
  end

  it "classifies organic when logistic fit is strong" do
    channel.update!(created_at: 30.days.ago)
    # Smooth sigmoid-ish growth
    (0..20).each do |i|
      followers = (1000 * (1 + ::Math.tanh((i - 10) / 3.0))).to_i
      create(:follower_snapshot, channel: channel, timestamp: (30 - i).days.ago, followers_count: followers.clamp(10, 100_000))
    end

    result = described_class.call(channel)

    expect(%w[organic missing]).to include(result[:status])
    expect(result[:score]).not_to be_nil if result[:status] == "organic"
  end
end
