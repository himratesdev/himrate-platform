# frozen_string_literal: true

require "rails_helper"

RSpec.describe CrossChannelDigestRefreshWorker do
  let(:worker) { described_class.new }
  let(:ch_client) { instance_double(Clickhouse::Client) }
  let(:redis) { instance_double(Redis) }

  before do
    allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(true)
    allow(Clickhouse).to receive(:client).and_return(ch_client)
    # CR-258 S2: most tests expect the lock to be acquired (no overlap). Specific overlap-skip
    # test below overrides this.
    allow(Sidekiq).to receive(:redis).and_yield(redis)
    allow(redis).to receive(:set).with(described_class::OVERLAP_LOCK_KEY, anything, nx: true, ex: described_class::OVERLAP_LOCK_TTL).and_return(true)
    allow(redis).to receive(:del).with(described_class::OVERLAP_LOCK_KEY).and_return(1)
  end

  it "skips when Flipper :cross_channel_digest disabled" do
    allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(false)
    expect(ch_client).not_to receive(:select)
    worker.perform
  end

  it "upserts rows from the CH aggregation" do
    allow(ch_client).to receive(:select).and_return([
      { "username" => "alice", "c" => "5" },
      { "username" => "bob",   "c" => "3" }
    ])

    expect { worker.perform }.to change(CrossChannelDigest, :count).from(0).to(2)
    expect(CrossChannelDigest.find("alice").distinct_channels_24h).to eq(5)
    expect(CrossChannelDigest.find("bob").distinct_channels_24h).to eq(3)
  end

  it "updates existing rows in place (idempotent refresh)" do
    older = 2.hours.ago
    CrossChannelDigest.upsert_all([
      { username: "alice", distinct_channels_24h: 1, refreshed_at: older }
    ], unique_by: :username)

    allow(ch_client).to receive(:select).and_return([
      { "username" => "alice", "c" => "9" }
    ])

    worker.perform

    row = CrossChannelDigest.find("alice")
    expect(row.distinct_channels_24h).to eq(9)
    expect(row.refreshed_at).to be > older
  end

  it "prunes rows whose refreshed_at is older than STALE_AFTER" do
    stale = 26.hours.ago
    CrossChannelDigest.upsert_all([
      { username: "ghost", distinct_channels_24h: 4, refreshed_at: stale }
    ], unique_by: :username)
    allow(ch_client).to receive(:select).and_return([]) # CH returns no fresh rows

    worker.perform

    expect(CrossChannelDigest.exists?("ghost")).to be false
  end

  it "keeps rows whose refreshed_at is within STALE_AFTER" do
    recent = 23.hours.ago
    CrossChannelDigest.upsert_all([
      { username: "active", distinct_channels_24h: 4, refreshed_at: recent }
    ], unique_by: :username)
    allow(ch_client).to receive(:select).and_return([])

    worker.perform

    expect(CrossChannelDigest.exists?("active")).to be true
  end

  it "skips gracefully when CH returns an error (no exception, no upsert)" do
    allow(ch_client).to receive(:select).and_raise(Clickhouse::QueryError.new("boom"))

    expect { worker.perform }.not_to raise_error
    expect(CrossChannelDigest.count).to eq(0)
  end

  it "batches upserts when result exceeds UPSERT_BATCH_SIZE" do
    rows = (1..described_class::UPSERT_BATCH_SIZE + 5).map do |i|
      { "username" => "user#{i}", "c" => "2" }
    end
    allow(ch_client).to receive(:select).and_return(rows)

    expect(CrossChannelDigest).to receive(:upsert_all).at_least(:twice).and_call_original
    worker.perform

    expect(CrossChannelDigest.count).to eq(described_class::UPSERT_BATCH_SIZE + 5)
  end

  # CR-258 S2: overlap guard. If CH aggregation runs past the 5-min cron interval (the exact
  # scenario this PR is meant to mitigate), the next cron tick must NOT spawn a second
  # concurrent worker that piles a duplicate CH scan on already-stressed CH.
  describe "overlap lock (CR-258 S2)" do
    it "skips the run entirely when the lock is held by another worker" do
      allow(redis).to receive(:set).and_return(nil) # SETNX fails — another tick is in flight
      expect(ch_client).not_to receive(:select)
      expect(CrossChannelDigest).not_to receive(:upsert_all)
      # CR-258 iter-2 M-iter2-1: the loser tick must NOT DEL the winner's lock in its ensure-block.
      # Without the @lock_held guard, ensure ran unconditionally and the loser's release_lock
      # would have wiped the winner's key.
      expect(redis).not_to receive(:del)
      expect(Rails.logger).to receive(:info).with(/overlap lock held/)

      worker.perform
    end

    it "releases the lock after a successful run (next tick can acquire)" do
      allow(ch_client).to receive(:select).and_return([])
      expect(redis).to receive(:del).with(described_class::OVERLAP_LOCK_KEY)
      worker.perform
    end

    it "releases the lock even if the run raises (ensure-block)" do
      allow(ch_client).to receive(:select).and_raise(StandardError.new("unexpected"))
      expect(redis).to receive(:del).with(described_class::OVERLAP_LOCK_KEY)
      expect { worker.perform }.to raise_error(StandardError, "unexpected")
    end

    it "proceeds (fail-open) when Redis is unavailable for lock acquire" do
      allow(redis).to receive(:set).and_raise(Redis::CannotConnectError.new("redis down"))
      expect(ch_client).to receive(:select).and_return([])
      expect(Rails.logger).to receive(:warn).with(/lock acquire failed/)

      worker.perform
    end
  end
end
