# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::FollowerCcvCouplingTimeline do
  let(:channel) { create(:channel) }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "coupling", param_name: "rolling_window_days", param_value: 30, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "coupling", param_name: "healthy_r_min", param_value: 0.7, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "coupling", param_name: "weakening_r_min", param_value: 0.3, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "coupling", param_name: "min_history_days", param_value: 7, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  it "returns nil timeline r when insufficient history" do
    result = described_class.call(channel: channel, from: 3.days.ago.to_date, to: Time.current.to_date)

    expect(result[:timeline].all? { |row| row[:r].nil? }).to be true
    expect(result[:summary][:current_r]).to be_nil
  end

  it "classifies healthy when correlation strong positive" do
    14.times do |i|
      date = i.days.ago.to_date
      # Both grow together linearly
      create(:follower_snapshot, channel: channel, timestamp: date.beginning_of_day, followers_count: 1000 + i * 100)
      create(:trends_daily_aggregate, channel: channel, date: date, ccv_avg: 500 + i * 50, ti_avg: 70)
    end

    result = described_class.call(channel: channel, from: 3.days.ago.to_date, to: Time.current.to_date)

    expect(result[:summary][:current_health]).to eq("healthy")
  end

  it "classifies decoupled when correlation near zero/negative" do
    14.times do |i|
      date = i.days.ago.to_date
      # Followers monotonic up, CCV noisy
      create(:follower_snapshot, channel: channel, timestamp: date.beginning_of_day, followers_count: 1000 + i * 100)
      ccv = i.even? ? 500 : 5000
      create(:trends_daily_aggregate, channel: channel, date: date, ccv_avg: ccv, ti_avg: 70)
    end

    result = described_class.call(channel: channel, from: 3.days.ago.to_date, to: Time.current.to_date)

    expect(%w[decoupled weakening]).to include(result[:summary][:current_health])
  end
end
