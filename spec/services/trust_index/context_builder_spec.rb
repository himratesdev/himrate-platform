# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::ContextBuilder do
  let(:channel) { Channel.create!(twitch_id: "cb_ch", login: "cb_channel", display_name: "CB") }
  let(:stream) { Stream.create!(channel: channel, started_at: 1.hour.ago, game_name: "Just Chatting") }

  it "returns Hash with all expected keys" do
    context = described_class.build(stream)

    expected_keys = %i[
      latest_ccv latest_chatters ccv_series_15min ccv_series_30min ccv_series_10min
      chat_rate_10min unique_chatters_60min bot_scores channel_protection_config
      cross_channel_counts raids recent_raids category stream_duration_min
    ]
    expect(context.keys).to match_array(expected_keys)
  end

  it "fetches latest CCV from snapshots" do
    CcvSnapshot.create!(stream: stream, timestamp: 5.minutes.ago, ccv_count: 500)
    CcvSnapshot.create!(stream: stream, timestamp: 1.minute.ago, ccv_count: 800)

    context = described_class.build(stream)
    expect(context[:latest_ccv]).to eq(800)
  end

  it "builds CCV series limited by time window" do
    20.times { |i| CcvSnapshot.create!(stream: stream, timestamp: (20 - i).minutes.ago, ccv_count: 500 + i) }

    context = described_class.build(stream)
    expect(context[:ccv_series_15min].size).to be <= 15
    expect(context[:ccv_series_30min].size).to eq(20)
  end

  it "resolves category from game_name" do
    context = described_class.build(stream)
    expect(context[:category]).to eq("just_chatting")
  end

  it "returns nils gracefully when no data" do
    context = described_class.build(stream)
    expect(context[:latest_ccv]).to be_nil
    expect(context[:latest_chatters]).to be_nil
    expect(context[:bot_scores]).to eq([])
    expect(context[:raids]).to eq([])
  end

  it "calculates stream duration in minutes" do
    context = described_class.build(stream)
    expect(context[:stream_duration_min]).to be_between(59, 61)
  end
end
