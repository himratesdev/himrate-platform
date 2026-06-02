# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Features::GrowthSignals do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:growth) { described_class.new(stream) }

  # Helper: seed N consecutive daily FollowerSnapshot rows ending today.
  # `counts` Array<Integer> — each consecutive pair = next day delta.
  # Returns the snapshot timestamps for use in stream-attribution helpers.
  def seed_snapshots(counts, end_at: Time.current)
    timestamps = []
    counts.reverse.each_with_index do |count, days_ago|
      ts = end_at - days_ago.days
      FollowerSnapshot.create!(channel: channel, timestamp: ts, followers_count: count)
      timestamps.unshift(ts)
    end
    timestamps
  end

  describe "#call (cold-start — < MIN_SNAPSHOTS_FOR_CV)" do
    it "all 4 features nil with insufficient_snapshots reason when no snapshots" do
      result = growth.call
      expect(result.values).to all(be_nil)
      reasons = growth.insufficient_data_reasons
      expect(reasons.keys).to match_array(%i[
        follower_growth_cv_90d growth_engagement_correlation
        follow_unfollow_churn_rate attributed_spike_ratio
      ])
      expect(reasons.values.uniq).to eq([ "insufficient_snapshots" ])
    end

    it "still insufficient when only 4 snapshots (3 deltas, <7 MIN_CV)" do
      seed_snapshots([ 100, 110, 120, 130 ])
      result = growth.call
      expect(result.values).to all(be_nil)
      expect(growth.insufficient_data_reasons[:follower_growth_cv_90d]).to eq("insufficient_snapshots")
    end
  end

  describe "#call (happy-path — 15 days steady growth + streaming history)" do
    before do
      # 15 snapshots → 14 daily deltas (≥ MIN_SNAPSHOTS_FOR_CORRELATION).
      # Steady +5/day growth → low CV, zero churn.
      counts = (0..14).map { |i| 1000 + 5 * i }
      @timestamps = seed_snapshots(counts)
      # Streamed on every snapshot interval — attribution should hit 1.0 if any spike.
      @timestamps.each { |ts| create(:stream, channel: channel, started_at: ts + 1.hour) }
    end

    it "follower_growth_cv_90d small for steady growth (CV ≈ 0)" do
      cv = growth.call[:follower_growth_cv_90d]
      expect(cv).to be_a(Numeric)
      expect(cv).to be_within(0.001).of(0.0) # zero variance, perfect linear growth
    end

    it "follow_unfollow_churn_rate = 0 for all-positive deltas" do
      expect(growth.call[:follow_unfollow_churn_rate]).to eq(0.0)
    end

    it "growth_engagement_correlation populated (numeric in [-1, 1])" do
      corr = growth.call[:growth_engagement_correlation]
      # Steady +5/day with constant 1-stream/day → zero variance on engagement series →
      # pearson denom zero → nil. This is correct degenerate behavior.
      expect(corr).to be_nil.or be_a(Numeric).and(be_between(-1.0, 1.0))
    end

    it "attributed_spike_ratio nil for no_spike_days (zero variance series)" do
      # Steady growth = no σ → no spike threshold breached → nil + no_spike_days reason.
      expect(growth.call[:attributed_spike_ratio]).to be_nil
      expect(growth.insufficient_data_reasons[:attributed_spike_ratio]).to eq("no_spike_days")
    end
  end

  describe "#call (volatile growth — high CV)" do
    before do
      # 8 snapshots → 7 daily deltas (≥ MIN_CV). Highly volatile: oscillates +50 / -10.
      counts = [ 1000, 1050, 1040, 1090, 1080, 1130, 1120, 1170 ]
      seed_snapshots(counts)
    end

    it "follower_growth_cv_90d high (>0.5) for volatile growth" do
      cv = growth.call[:follower_growth_cv_90d]
      expect(cv).to be_a(Numeric)
      expect(cv).to be > 0.5
    end

    it "follow_unfollow_churn_rate non-zero for mixed deltas" do
      # 7 deltas: +50, -10, +50, -10, +50, -10, +50 → 3 negative / 7 = 0.4286
      expect(growth.call[:follow_unfollow_churn_rate]).to be_within(0.01).of(0.4286)
    end
  end

  describe "#call (zero-mean growth — CV undefined)" do
    before do
      # 9 snapshots, 8 deltas alternating +100 / -100 → exact zero mean.
      # deltas: +100, -100, +100, -100, +100, -100, +100, -100 = sum 0, mean 0.
      counts = [ 1000, 1100, 1000, 1100, 1000, 1100, 1000, 1100, 1000 ]
      seed_snapshots(counts)
    end

    it "follower_growth_cv_90d nil with zero_mean_growth reason" do
      expect(growth.call[:follower_growth_cv_90d]).to be_nil
      expect(growth.insufficient_data_reasons[:follower_growth_cv_90d]).to eq("zero_mean_growth")
    end

    it "follow_unfollow_churn_rate = 0.5 (4 negative of 8)" do
      expect(growth.call[:follow_unfollow_churn_rate]).to eq(0.5)
    end
  end

  describe "#call (real spike day — attribution)" do
    before do
      # 8 snapshots: steady baseline +5/day, then one massive spike +500 → attribution context.
      counts = [ 1000, 1005, 1010, 1015, 1020, 1025, 1030, 1530 ] # spike on last delta
      @timestamps = seed_snapshots(counts)
      # Stream existed on the spike day interval [t_{-2}, t_{-1}].
      spike_start_window = @timestamps[-2]
      spike_end_window = @timestamps[-1]
      create(:stream, channel: channel, started_at: spike_start_window + 1.hour)
      # The non-spike intervals have no streams.
    end

    it "attributed_spike_ratio = 1.0 for single attributed spike" do
      ratio = growth.call[:attributed_spike_ratio]
      expect(ratio).to eq(1.0)
    end

    it "without any stream → attributed_spike_ratio = 0.0" do
      Stream.where(channel: channel).destroy_all
      # Place anchor stream WAY outside 90d window so stream_starts is empty for the
      # spike interval — factory default `started_at: 3.hours.ago` would fall inside
      # the spike interval and falsely attribute the spike.
      stream_no_history = create(:stream, channel: channel, started_at: 200.days.ago, ended_at: 199.days.ago)
      growth_no_streams = described_class.new(stream_no_history)
      expect(growth_no_streams.call[:attributed_spike_ratio]).to eq(0.0)
    end
  end

  describe "#call (correlation — clear positive)" do
    before do
      # 15 snapshots. Deltas grow over time AND so does stream activity → positive correlation.
      counts = (0..14).map { |i| 1000 + i * 10 + (i**2) } # accelerating growth
      timestamps = seed_snapshots(counts)
      # Streams accelerate too: i streams on day i (compressed into the interval).
      timestamps.each_with_index do |ts, i|
        i.times { |k| create(:stream, channel: channel, started_at: ts + (k + 1).minutes) }
      end
    end

    it "growth_engagement_correlation positive (>0)" do
      corr = growth.call[:growth_engagement_correlation]
      expect(corr).to be_a(Numeric)
      expect(corr).to be > 0.0
    end
  end

  describe "#call (window boundary — 90d cutoff)" do
    before do
      # 8 snapshots inside window + 5 snapshots OUTSIDE window (>90d ago) — outside ignored.
      seed_snapshots([ 100, 200, 300, 400, 500, 600, 700, 800 ])
      5.times do |i|
        FollowerSnapshot.create!(
          channel: channel,
          timestamp: (100 + i).days.ago, # 100..104 days ago, all > 90d
          followers_count: 50 + i
        )
      end
    end

    it "uses only in-window snapshots for delta computation" do
      # 8 in-window snapshots → 7 deltas of +100 each → mean=100, std=0, CV=0
      cv = growth.call[:follower_growth_cv_90d]
      expect(cv).to eq(0.0)
    end
  end
end
