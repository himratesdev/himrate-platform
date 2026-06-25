# frozen_string_literal: true

require "rails_helper"

# T1-064 FR-3: Reputation Categorical band derivation (TI rolling window + anomaly distribution).
RSpec.describe Reputation::BandService do
  # Builds a channel with `ti_scores.size` completed streams, one final TIH per stream,
  # and a severe (viewbot_spike) anomaly on the first `severe_streams` of them.
  def build_channel(ti_scores, severe_streams: 0, tih: :all)
    channel = create(:channel)
    count = ti_scores.size
    ti_scores.each_with_index do |score, i|
      ended = (count - i).hours.ago
      stream = create(:stream, channel: channel, started_at: ended - 2.hours, ended_at: ended)
      if tih == :all || (tih == :partial && i.even?)
        create(:trust_index_history, channel: channel, stream: stream,
                                     trust_index_score: score, calculated_at: ended)
      end
      create(:anomaly, stream: stream, anomaly_type: "viewbot_spike") if i < severe_streams
    end
    channel
  end

  def band_for(channel)
    described_class.new(channel).call
  end

  describe "#call cold-start gating (FD-4 — 3 tiers, never bare nil)" do
    it "returns band=nil with insufficient tier + stream_count for <3 completed streams" do
      result = band_for(build_channel([ 90, 90 ]))
      expect(result).to eq(band: nil, tier: "insufficient", stream_count: 2)
    end

    it "maps 3–6 streams to the basic tier (was provisional_low) with stream_count for the tooltip" do
      result = band_for(build_channel(Array.new(5, 90)))
      expect(result[:tier]).to eq("basic")
      expect(result[:stream_count]).to eq(5)
      expect(result[:band]).not_to be_nil
    end

    it "maps 7–9 streams to the basic tier (was provisional)" do
      result = band_for(build_channel(Array.new(8, 90)))
      expect(result[:tier]).to eq("basic")
      expect(result[:stream_count]).to eq(8)
    end

    it "maps >=10 streams to the full tier" do
      result = band_for(build_channel(Array.new(12, 90)))
      expect(result[:tier]).to eq("full")
      expect(result[:band]).to eq("impeccable")
    end
  end

  describe "#call band derivation (ADR DEC-1)" do
    it "impeccable: high mean TI, zero variance, no severe anomalies" do
      expect(band_for(build_channel(Array.new(10, 90)))[:band]).to eq("impeccable")
    end

    it "stable: good mean TI, low variance, no severe anomalies" do
      expect(band_for(build_channel(Array.new(10, 75)))[:band]).to eq("stable")
    end

    it "variable: high TI variance (stddev > 15) breaks stability" do
      scores = Array.new(10) { |i| i.even? ? 55 : 95 } # mean 75, stddev 20
      expect(band_for(build_channel(scores))[:band]).to eq("variable")
    end

    it "unstable: low mean TI (< 50)" do
      expect(band_for(build_channel(Array.new(10, 45)))[:band]).to eq("unstable")
    end

    it "unstable: high severe-anomaly rate (> 0.34) even with good TI" do
      result = band_for(build_channel(Array.new(10, 80), severe_streams: 4)) # rate 0.4
      expect(result[:band]).to eq("unstable")
    end

    it "stable tolerates a low severe-anomaly rate (<= 0.1)" do
      result = band_for(build_channel(Array.new(10, 75), severe_streams: 1)) # rate 0.1
      expect(result[:band]).to eq("stable")
    end

    it "ignores benign anomaly types (organic_spike/host_raid)" do
      channel = build_channel(Array.new(10, 90))
      channel.streams.each { |s| create(:anomaly, stream: s, anomaly_type: "host_raid") }
      expect(band_for(channel)[:band]).to eq("impeccable") # benign do not penalize
    end
  end

  describe "#call severe-anomaly whitelist + distinct-stream (BUG-band-unstable)" do
    it "ignores statistical CCV-shape detector fires (ccv_step_function/ccv_tier_clustering)" do
      # Prod: honest channels carry hundreds of these per window (recrent 118+79) — must NOT count.
      channel = build_channel(Array.new(10, 90))
      channel.streams.each do |s|
        10.times { create(:anomaly, stream: s, anomaly_type: "ccv_step_function") }
        create(:anomaly, stream: s, anomaly_type: "ccv_tier_clustering")
      end
      expect(band_for(channel)[:band]).to eq("impeccable")
    end

    it "ignores routine TI-signal anomalies (ti_drop / erv_divergence)" do
      channel = build_channel(Array.new(10, 90))
      channel.streams.each do |s|
        create(:anomaly, stream: s, anomaly_type: "ti_drop")
        create(:anomaly, stream: s, anomaly_type: "erv_divergence")
      end
      expect(band_for(channel)[:band]).to eq("impeccable")
    end

    it "counts DISTINCT streams with a bot event, not raw anomaly rows" do
      # 50 viewbot rows on ONE stream → 1 severe stream / 10 = rate 0.1 (stable), not 5.0 (unstable).
      channel = build_channel(Array.new(10, 75))
      one = channel.streams.first
      50.times { create(:anomaly, stream: one, anomaly_type: "viewbot_spike") }
      expect(band_for(channel)[:band]).to eq("stable")
    end

    it "still flags a genuinely botted channel (bot events on > 1/3 of window streams)" do
      # known_bot_match (whitelist) on 4/10 streams → rate 0.4 > 0.34 → unstable.
      channel = build_channel(Array.new(10, 80))
      channel.streams.first(4).each { |s| create(:anomaly, stream: s, anomaly_type: "known_bot_match") }
      expect(band_for(channel)[:band]).to eq("unstable")
    end
  end

  describe "#call edge cases" do
    it "derives from available TIH when some streams lack a snapshot (partial window)" do
      result = band_for(build_channel(Array.new(10, 90), tih: :partial))
      expect(result[:tier]).to eq("full")
      expect(result[:band]).to eq("impeccable")
    end

    it "returns band=nil when fewer than 2 TI scores are available" do
      channel = create(:channel)
      3.times { |i| create(:stream, channel: channel, started_at: (i + 2).hours.ago, ended_at: (i + 1).hours.ago) }
      # no TIH rows → cannot derive
      expect(band_for(channel)[:band]).to be_nil
    end
  end

  describe ".refresh / .cached_for caching" do
    it "warms and reads the cache" do
      channel = build_channel(Array.new(10, 90))
      written = described_class.refresh(channel)
      expect(written[:band]).to eq("impeccable")
      expect(Rails.cache.read(described_class.cache_key(channel.id))).to eq(written)
      expect(described_class.cached_for(channel)).to eq(written)
    end
  end

  # T1-065 DEC-2: the pure band cascade extracted for Reputation::HistoryService trajectory reuse.
  describe ".classify (single-source band cascade)" do
    it "classifies by level + stability + anomaly rate" do
      expect(described_class.classify(Array.new(5, 90.0), 0.0)).to eq("impeccable")
      expect(described_class.classify(Array.new(5, 75.0), 0.0)).to eq("stable")
      expect(described_class.classify([ 90.0, 60.0, 95.0, 55.0, 88.0 ], 0.0)).to eq("variable")
      expect(described_class.classify(Array.new(5, 40.0), 0.0)).to eq("unstable")
      expect(described_class.classify(Array.new(5, 90.0), 0.5)).to eq("unstable") # rate > UNSTABLE_RATE
    end

    it "is the method #derive_band delegates to (instance behaviour unchanged)" do
      # full-tier clean channel → instance #call still yields the classify result.
      expect(band_for(build_channel(Array.new(10, 90)))[:band]).to eq("impeccable")
    end
  end
end
