# frozen_string_literal: true

require "rails_helper"

RSpec.describe CrossChannelDigestRefreshWorker do
  let(:worker) { described_class.new }
  let(:ch_client) { instance_double(Clickhouse::Client) }

  before do
    allow(Flipper).to receive(:enabled?).with(:cross_channel_digest).and_return(true)
    allow(Clickhouse).to receive(:client).and_return(ch_client)
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
end
