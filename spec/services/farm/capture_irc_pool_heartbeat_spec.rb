# frozen_string_literal: true

require "rails_helper"

# BUG T-F1 2026-09-05: the pool heartbeat must expose acknowledged vs in-flight vs parked JOINs.
RSpec.describe Farm::CaptureIrcPool, "heartbeat join accounting" do
  let(:capture_set) { instance_double(Farm::CaptureSet) }
  let(:pool) { described_class.new(connections: 2, max_per_conn: 10, capture_set: capture_set) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
    pool.shards.each do |shard|
      ssl = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
      allow(ssl).to receive(:write)
      shard.instance_variable_set(:@ssl_socket, ssl)
      allow(shard).to receive(:push_to_redis)
    end
  end

  it "sums joined / unacked / gave_up across shards and reports them per shard" do
    pool.join("acked")
    pool.join("inflight")
    pool.shards.each { |s| s.send(:process_pending_joins) }
    pool.shard_for("acked").send(:process_line, ":tmi.twitch.tv ROOMSTATE #acked")

    payload = pool.heartbeat_payload

    expect(payload[:channels]).to eq(2)
    expect(payload[:joined]).to eq(1)
    expect(payload[:unacked]).to eq(1)
    expect(payload[:join_gave_up]).to eq(0)
    expect(payload[:shards].sum { |s| s[:joined] }).to eq(1)
    expect(payload[:shards].sum { |s| s[:unacked] }).to eq(1)
    expect(payload[:shards].first.keys).to include(:joined, :unacked, :gave_up, :connected)
  end
end
