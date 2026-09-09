# frozen_string_literal: true

require "rails_helper"

# Real ClickHouse in CI — the finding IS the query, so mocking the client would test nothing.
RSpec.describe Clickhouse::CoordinationQueries do
  let(:a) { ns("chan_a") }
  let(:b) { ns("chan_b") }
  let(:c) { ns("chan_c") }
  let(:hour) { 2.hours.ago.utc.beginning_of_hour }
  let(:bots) { (1..6).map { |i| ns("bot#{i}") } }

  describe ".collect_hour!" do
    it "keeps the channel identities the T1-057 query throws away" do
      # Two bursts inside the hour so the account clears the >= 2 events floor.
      seed_chat_burst(hour + 5.minutes, [ a, b, c ], bots)
      seed_chat_burst(hour + 20.minutes, [ a, b, c ], bots)

      described_class.collect_hour!(hour)

      row = described_class.accounts(days: 1).find { |r| r[:username] == bots.first }
      expect(row).to be_present
      expect(row[:channels]).to match_array([ a, b, c ])
      expect(row[:events]).to eq(2)
      expect(row[:max_concurrent]).to eq(3)
    end

    it "ignores an account that posts in fewer than three channels at once" do
      seed_chat_burst(hour + 5.minutes, [ a, b ], bots)
      seed_chat_burst(hour + 20.minutes, [ a, b ], bots)

      described_class.collect_hour!(hour)

      expect(described_class.accounts(days: 1).map { |r| r[:username] }).not_to include(*bots)
    end

    it "is idempotent — recollecting an hour replaces it instead of doubling the events" do
      seed_chat_burst(hour + 5.minutes, [ a, b, c ], bots)
      seed_chat_burst(hour + 20.minutes, [ a, b, c ], bots)

      # No OPTIMIZE: the reads use FINAL precisely so a re-collection cannot inflate the counts
      # while the background merge is still pending.
      2.times { described_class.collect_hour!(hour) }

      row = described_class.accounts(days: 1).find { |r| r[:username] == bots.first }
      expect(row[:events]).to eq(2)
    end
  end

  describe ".collected_hours" do
    # Regression: the projection used to be aliased `hour`, which shadows the DateTime column in
    # the WHERE clause and makes ClickHouse reject the comparison. The worker stubs this method in
    # its own spec, so nothing executed the SQL and the hourly collector died silently in prod.
    it "returns the hours already collected, as real times" do
      seed_coordination(hour, ns("collected") => { channels: [ a, b, c ], events: 2, max_concurrent: 3 })

      result = described_class.collected_hours(hours: 26)

      expect(result).to be_an(Array)
      expect(result).to all(be_a(ActiveSupport::TimeWithZone))
      expect(result.map(&:to_i)).to include(hour.to_i)
    end

    it "ignores hours outside the lookback" do
      old_hour = 40.hours.ago.utc.beginning_of_hour
      seed_coordination(old_hour, ns("ancient") => { channels: [ a, b, c ], events: 2, max_concurrent: 3 })

      expect(described_class.collected_hours(hours: 26).map(&:to_i)).not_to include(old_hour.to_i)
    end
  end

  describe ".accounts" do
    it "drops roamers — an account spread across too many channels is a viewer, not a pool member" do
      wide = ns("roamer")
      seed_coordination(hour, wide => { channels: (1..25).map { |i| ns("w#{i}") }, events: 9, max_concurrent: 4 })

      expect(described_class.accounts(days: 1).map { |r| r[:username] }).not_to include(wide)
    end

    it "drops an account whose widest burst exceeds the dedicated-pool signature" do
      spammer = ns("spammer")
      seed_coordination(hour, spammer => { channels: [ a, b, c ], events: 9, max_concurrent: 20 })

      expect(described_class.accounts(days: 1).map { |r| r[:username] }).not_to include(spammer)
    end

    it "unions the channel sets of an account seen across several hours" do
      user = ns("multi")
      seed_coordination(hour, user => { channels: [ a, b, c ], events: 2, max_concurrent: 3 })
      seed_coordination(hour - 1.hour, user => { channels: [ a, b, ns("later") ], events: 2, max_concurrent: 3 })

      row = described_class.accounts(days: 1).find { |r| r[:username] == user }
      expect(row[:channels].size).to eq(4)
      expect(row[:events]).to eq(4)
    end
  end

  describe ".channel_pairs" do
    it "returns one row per unordered pair with the shared-account count" do
      pool = (1..6).map { |i| ns("pool#{i}") }
      pool.each { |u| seed_coordination(hour, u => { channels: [ a, b, c ], events: 3, max_concurrent: 3 }) }

      pairs = described_class.channel_pairs(days: 1).select { |p| [ p[:a], p[:b] ].all? { |x| [ a, b, c ].include?(x) } }

      expect(pairs.size).to eq(3)
      expect(pairs.map { |p| p[:accounts_shared] }.uniq).to eq([ 6 ])
      expect(pairs.all? { |p| p[:a] < p[:b] }).to be(true)
    end

    it "drops a pair under the shared-account floor" do
      thin = (1..3).map { |i| ns("thin#{i}") }
      thin.each { |u| seed_coordination(hour, u => { channels: [ a, b, c ], events: 3, max_concurrent: 3 }) }

      pairs = described_class.channel_pairs(days: 1).select { |p| [ p[:a], p[:b] ].all? { |x| [ a, b, c ].include?(x) } }
      expect(pairs).to be_empty
    end
  end

  describe ".rhythm" do
    it "reports a near-zero spread for metronomic posting" do
      user = ns("metronome")
      10.times { |i| seed_chat_burst(hour + (i * 30).seconds, [ a ], [ user ]) }

      result = described_class.rhythm([ a ], [ user ])

      expect(result[user][:median_interval_sec]).to eq(30.0)
      expect(result[user][:interval_cv]).to eq(0.0)
    end

    it "returns nothing for an empty input instead of building a query" do
      expect(described_class.rhythm([], [ "x" ])).to eq({})
      expect(described_class.rhythm([ a ], [])).to eq({})
    end
  end
end
