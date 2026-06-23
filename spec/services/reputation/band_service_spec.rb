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

  describe "#call cold-start gating (FR-4 — never bare nil)" do
    it "returns band=nil with insufficient tier for <3 completed streams" do
      result = band_for(build_channel([ 90, 90 ]))
      expect(result).to eq(band: nil, tier: "insufficient", provisional: false)
    end

    it "flags provisional for 3–6 streams (provisional_low tier)" do
      result = band_for(build_channel(Array.new(5, 90)))
      expect(result[:tier]).to eq("provisional_low")
      expect(result[:provisional]).to be(true)
      expect(result[:band]).not_to be_nil
    end

    it "flags provisional for 7–9 streams (provisional tier)" do
      result = band_for(build_channel(Array.new(8, 90)))
      expect(result[:tier]).to eq("provisional")
      expect(result[:provisional]).to be(true)
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
end
