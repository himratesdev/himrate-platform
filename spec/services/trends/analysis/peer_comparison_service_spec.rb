# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Analysis::PeerComparisonService do
  let(:channel) { create(:channel) }
  let(:category) { "Just Chatting" }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "peer_comparison", param_name: "min_category_channels", param_value: 3, created_at: Time.current, updated_at: Time.current },
      { signal_type: "trends", category: "peer_comparison", param_name: "cache_ttl_minutes", param_value: 15, created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)

    Rails.cache.clear
  end

  describe ".call" do
    it "returns insufficient_data когда peers < min_category_channels" do
      result = described_class.call(channel: channel, category: category, period: "30d")

      expect(result[:insufficient_data]).to be true
      expect(result[:sample_size]).to eq(0)
    end

    it "computes percentiles для enough peers" do
      5.times do |_i|
        peer = create(:channel)
        create(:trends_daily_aggregate, channel: peer, date: 5.days.ago.to_date,
          categories: { category => 1 }, ti_avg: 60 + rand(30), erv_avg_percent: 70 + rand(20), ti_std: 5)
      end
      create(:trends_daily_aggregate, channel: channel, date: 3.days.ago.to_date,
        categories: { category => 1 }, ti_avg: 85, erv_avg_percent: 90, ti_std: 3)

      result = described_class.call(channel: channel, category: category, period: "30d")

      expect(result[:insufficient_data]).to be_falsey
      expect(result[:sample_size]).to eq(5)
      expect(result[:channel_values]).to include(:ti_avg, :erv_avg_percent, :stability)
      expect(result[:percentiles][:ti]).to include(:p25, :p50, :p75, :p90)
    end

    it "excludes self из peers (build-for-years: no self-comparison)" do
      3.times do |_|
        peer = create(:channel)
        create(:trends_daily_aggregate, channel: peer, date: 3.days.ago.to_date,
          categories: { category => 1 }, ti_avg: 70, erv_avg_percent: 80, ti_std: 4)
      end
      create(:trends_daily_aggregate, channel: channel, date: 3.days.ago.to_date,
        categories: { category => 1 }, ti_avg: 99, erv_avg_percent: 99, ti_std: 2)

      result = described_class.call(channel: channel, category: category, period: "30d")

      # P50 peers = 70 (channel 99 не в peers).
      expect(result[:percentiles][:ti][:p50]).to eq(70.0)
    end

    it "computes stability = 1 - ti_std/ti_avg" do
      3.times do |_|
        peer = create(:channel)
        create(:trends_daily_aggregate, channel: peer, date: 3.days.ago.to_date,
          categories: { category => 1 }, ti_avg: 80, erv_avg_percent: 85, ti_std: 8)
      end
      create(:trends_daily_aggregate, channel: channel, date: 3.days.ago.to_date,
        categories: { category => 1 }, ti_avg: 70, erv_avg_percent: 75, ti_std: 7)

      result = described_class.call(channel: channel, category: category, period: "30d")

      # channel stability = 1 - 7/70 = 0.9
      expect(result[:channel_values][:stability]).to eq(0.9)
      # peer stability = 1 - 8/80 = 0.9
      expect(result[:percentiles][:stability][:p50]).to eq(0.9)
    end

    it "caches result (same call twice не re-computes)" do
      3.times do |_|
        peer = create(:channel)
        create(:trends_daily_aggregate, channel: peer, date: 3.days.ago.to_date,
          categories: { category => 1 }, ti_avg: 70, erv_avg_percent: 80, ti_std: 4)
      end

      allow(TrendsDailyAggregate).to receive(:where).and_call_original

      described_class.call(channel: channel, category: category, period: "30d")
      described_class.call(channel: channel, category: category, period: "30d")

      # Второй вызов cache hit — scope.where не трогается повторно.
      expect(TrendsDailyAggregate).to have_received(:where).at_most(:twice)
    end
  end
end
