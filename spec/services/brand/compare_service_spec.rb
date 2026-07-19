# frozen_string_literal: true

require "rails_helper"

RSpec.describe Brand::CompareService do
  def window_for(channel, ccv:, erv:, peak:, streams: 1)
    2.times { |i| create(:trends_daily_aggregate, channel: channel, date: (i + 1).days.ago.to_date, ccv_avg: ccv, erv_avg_percent: erv, ccv_peak: peak, streams_count: streams) }
  end

  it "rejects fewer than 2 or more than 4 channels" do
    expect(described_class.new(logins: %w[a]).call.error).to eq("CHANNELS_REQUIRED")
    expect(described_class.new(logins: %w[a b c d e]).call.error).to eq("CHANNELS_REQUIRED")
  end

  it "returns CHANNEL_NOT_FOUND when any login is missing" do
    create(:channel, login: "aaa")
    expect(described_class.new(logins: %w[aaa ghost]).call.error).to eq("CHANNEL_NOT_FOUND")
  end

  describe "columns + best_in_row + price" do
    let!(:a) { create(:channel, login: "aaa", display_name: "A") }
    let!(:b) { create(:channel, login: "bbb", display_name: "B") }

    before do
      window_for(a, ccv: 10_000, erv: 80.0, peak: 14_000) # real 8000
      window_for(b, ccv: 12_000, erv: 50.0, peak: 15_000) # real 6000
    end

    it "builds real audience columns, price-per-real-viewer, and best-in-row winners" do
      payload = described_class.new(logins: %w[aaa bbb], prices: %w[160000 90000]).call.payload

      cols = payload[:channels]
      expect(cols.map { |c| c[:login] }).to eq(%w[aaa bbb])
      expect(cols[0][:audience][:real_avg_viewers]).to eq(8_000)
      expect(cols[1][:audience][:real_avg_viewers]).to eq(6_000)
      expect(cols[0][:price][:per_real_viewer]).to eq(20.0) # 160000 / 8000
      expect(cols[1][:price][:per_real_viewer]).to eq(15.0) # 90000 / 6000

      expect(payload[:best_in_row][:real_avg_viewers]).to eq("aaa")          # 8000 > 6000
      expect(payload[:best_in_row][:price_per_real_viewer]).to eq("bbb")     # 15 < 20
      expect(payload[:deferred]).to include("unique_reach", "engagement_rate")
    end

    it "omits price rows and recommendation when no prices supplied" do
      payload = described_class.new(logins: %w[aaa bbb]).call.payload
      expect(payload[:channels].map { |c| c[:price] }).to all(be_nil)
      expect(payload[:recommendation]).to be_nil
      expect(payload[:best_in_row][:real_avg_viewers]).to eq("aaa") # audience rows still work
    end
  end

  it "recommends the cheapest price-per-real-viewer among recommendable bands (isolated)" do
    a = create(:channel, login: "aaa")
    b = create(:channel, login: "bbb")
    window_for(a, ccv: 10_000, erv: 80.0, peak: 14_000) # real 8000 → 160000/8000 = 20.0
    window_for(b, ccv: 10_000, erv: 80.0, peak: 14_000) # real 8000 → 120000/8000 = 15.0
    # isolate compare's recommendation logic from the reputation engine (test double, not prod mock):
    allow(Reputation::HistoryService).to receive(:cached_for).with(a).and_return(current: { band: "impeccable", tier: "full" })
    allow(Reputation::HistoryService).to receive(:cached_for).with(b).and_return(current: { band: "stable", tier: "full" })

    rec = described_class.new(logins: %w[aaa bbb], prices: %w[160000 120000]).call.payload[:recommendation]
    expect(rec[:login]).to eq("bbb")       # 15.0 < 20.0
    expect(rec[:per_real_viewer]).to eq(15.0)
  end

  it "does not drop the whole response when one channel is cold-start (partial)" do
    a = create(:channel, login: "aaa")
    create(:channel, login: "cold")
    window_for(a, ccv: 10_000, erv: 80.0, peak: 14_000)

    payload = described_class.new(logins: %w[aaa cold]).call.payload
    expect(payload[:channels][0][:audience][:available]).to be(true)
    expect(payload[:channels][1][:audience][:available]).to be(false)
    expect(payload[:best_in_row][:real_avg_viewers]).to eq("aaa") # cold column ignored, not zero
  end

  it "shares AudienceWindow with the streamer card (no drift)" do
    a = create(:channel, login: "aaa")
    b = create(:channel, login: "bbb")
    window_for(a, ccv: 9_000, erv: 70.0, peak: 12_000)
    window_for(b, ccv: 5_000, erv: 60.0, peak: 8_000)

    compare_real = described_class.new(logins: %w[aaa bbb]).call.payload[:channels].first[:audience][:real_avg_viewers]
    card_real = Brand::StreamerCardService.new(login: "aaa").call.payload[:layer1_real_audience][:real_avg_viewers]
    expect(compare_real).to eq(card_real) # same AudienceWindow → identical number
  end
end
