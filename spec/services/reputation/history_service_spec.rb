# frozen_string_literal: true

require "rails_helper"

# T1-065: Reputation history/trajectory — free trust-summary derivation.
RSpec.describe Reputation::HistoryService do
  # Builds a channel with `ti_scores.size` completed streams (one final TIH per stream unless
  # tih: :partial), an `erv_percent` per stream (defaults to the TI score), a severe (viewbot_spike)
  # anomaly on the first `severe_streams`, and `rep_rows` StreamerReputation history rows.
  def build_channel(ti_scores, erv_pcts: nil, severe_streams: 0, tih: :all, rep_rows: 0)
    channel = create(:channel)
    count = ti_scores.size
    ti_scores.each_with_index do |score, i|
      ended = (count - i).hours.ago
      stream = create(:stream, channel: channel, started_at: ended - 2.hours, ended_at: ended)
      if tih == :all || (tih == :partial && i.even?)
        create(:trust_index_history, channel: channel, stream: stream,
                                     trust_index_score: score,
                                     erv_percent: erv_pcts ? erv_pcts[i] : score,
                                     calculated_at: ended)
      end
      create(:anomaly, stream: stream, anomaly_type: "viewbot_spike") if i < severe_streams
    end
    rep_rows.times do |j|
      create(:streamer_reputation, channel: channel, calculated_at: (rep_rows - j).hours.ago)
    end
    channel
  end

  def payload_for(channel)
    described_class.new(channel).call
  end

  describe "TC-1 full channel" do
    it "returns full-tier trajectory + components + current band" do
      payload = payload_for(build_channel(Array.new(12, 90), rep_rows: 12))

      expect(payload[:current][:tier]).to eq("full")
      expect(payload[:current][:band]).to eq("impeccable")
      expect(payload[:real_audience_trajectory].size).to eq(12)
      expect(payload[:components_history].size).to eq(12)
      expect(payload[:window]).to eq(30)
    end

    it "caps trajectory + components at the 30-stream window" do
      payload = payload_for(build_channel(Array.new(35, 90), rep_rows: 35))

      expect(payload[:real_audience_trajectory].size).to eq(30)
      expect(payload[:components_history].size).to eq(30)
    end
  end

  describe "TC-9b AC-4 invariant (Option C — current == rightmost == BandService)" do
    it "makes current.band the rightmost trajectory point and equal to BandService#call" do
      channel = build_channel(Array.new(12, 90))
      payload = payload_for(channel)

      expect(payload[:current][:band]).to eq(payload[:real_audience_trajectory].last[:band])
      expect(payload[:current][:band]).to eq(Reputation::BandService.new(channel).call[:band])
    end

    it "keeps both nil at the scores.size<2 boundary (C1 scenario cannot diverge)" do
      # 10 completed streams (full tier) but only 1 has a TIH → scores.size<2 → band nil on BOTH
      # current and the rightmost trajectory point (they are the same computation).
      channel = build_channel(Array.new(10, 90), tih: :none)
      last_stream = channel.streams.where.not(ended_at: nil).order(:ended_at).last
      create(:trust_index_history, channel: channel, stream: last_stream,
                                   trust_index_score: 90, erv_percent: 90, calculated_at: last_stream.ended_at)

      payload = payload_for(channel)
      expect(Reputation::BandService.new(channel).call[:band]).to be_nil
      expect(payload[:current][:band]).to be_nil
      expect(payload[:real_audience_trajectory].last[:band]).to be_nil
    end
  end

  describe "TC-3 cold-start insufficient" do
    it "returns band nil + empty series (HTTP-200 honest-empty) for <3 streams" do
      payload = payload_for(build_channel(Array.new(2, 90)))

      expect(payload[:current]).to eq(band: nil, tier: "insufficient", stream_count: 2)
      expect(payload[:real_audience_trajectory]).to eq([])
      expect(payload[:components_history]).to eq([])
      expect(payload[:trend]).to eq(direction: nil, delta_pct: nil)
    end
  end

  describe "TC-4 cold-start basic" do
    it "returns trajectory + basic tier for 3-9 streams" do
      payload = payload_for(build_channel(Array.new(5, 90), rep_rows: 5))

      expect(payload[:current][:tier]).to eq("basic")
      expect(payload[:current][:band]).not_to be_nil
      expect(payload[:real_audience_trajectory].size).to eq(5)
    end
  end

  describe "TC-5 public components only" do
    it "exposes 3 components, never pattern_history_score" do
      payload = payload_for(build_channel(Array.new(12, 90), rep_rows: 3))
      keys = payload[:components_history].first.keys

      expect(keys).to contain_exactly(:calculated_at, :growth_pattern, :follower_quality, :engagement_consistency)
      expect(keys).not_to include(:pattern_history, :pattern_history_score)
    end
  end

  describe "TC-6 follower_quality stub flag" do
    it "flags follower_quality as stubbed" do
      expect(payload_for(build_channel(Array.new(12, 90)))[:follower_quality_stubbed]).to be(true)
    end
  end

  describe "TC-7 EC-6 stream without TIH" do
    it "keeps the point with null metrics and does not raise" do
      payload = payload_for(build_channel(Array.new(10, 90), tih: :partial))
      traj = payload[:real_audience_trajectory]

      expect(traj.size).to eq(10)
      expect(traj.any? { |p| p[:real_audience_pct].nil? }).to be(true)
    end
  end

  describe "TC-8 rolling-window band trajectory" do
    it "moves from unstable (early botted) to impeccable (later clean)" do
      payload = payload_for(build_channel([ 30 ] * 6 + [ 95 ] * 30))
      traj = payload[:real_audience_trajectory]

      expect(traj.first[:band]).to eq("unstable")
      expect(traj.last[:band]).to eq("impeccable")
    end
  end

  describe "TC-9a nil-anomaly severe_rate (lens A)" do
    it "computes without raising when window streams have no anomalies" do
      expect { payload_for(build_channel(Array.new(10, 90), severe_streams: 0)) }.not_to raise_error
      expect(payload_for(build_channel(Array.new(10, 90), severe_streams: 0))[:current][:band]).to eq("impeccable")
    end
  end

  describe "TC-9c EC-10 basic channel components vs trajectory" do
    it "returns empty components but present trajectory when no StreamerReputation rows" do
      payload = payload_for(build_channel(Array.new(5, 90), rep_rows: 0))

      expect(payload[:components_history]).to eq([])
      expect(payload[:real_audience_trajectory].size).to eq(5)
    end
  end

  describe "TC-9d trend descriptor (FR-8)" do
    it "reports improving when recent-half ERV% exceeds older-half by > threshold" do
      erv = (0..11).map { |i| 60 + (i * 3) } # 60..93 rising
      payload = payload_for(build_channel(Array.new(12, 90), erv_pcts: erv))

      expect(payload[:trend][:direction]).to eq("improving")
      expect(payload[:trend][:delta_pct]).to be > 5.0
    end

    it "reports stable when ERV% is flat" do
      payload = payload_for(build_channel(Array.new(12, 90), erv_pcts: Array.new(12, 80)))
      expect(payload[:trend][:direction]).to eq("stable")
    end

    it "returns null direction with fewer than 4 non-null points" do
      payload = payload_for(build_channel(Array.new(3, 90)))
      expect(payload[:trend]).to eq(direction: nil, delta_pct: nil)
    end
  end
end
