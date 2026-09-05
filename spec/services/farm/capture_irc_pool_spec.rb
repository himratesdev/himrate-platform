# frozen_string_literal: true

require "rails_helper"

# No network: shards are never #start-ed; we exercise routing, reconcile and the heartbeat payload.
RSpec.describe Farm::CaptureIrcPool do
  let(:capture_set) { instance_double(Farm::CaptureSet) }
  let(:pool) { described_class.new(connections: 3, max_per_conn: 5, capture_set: capture_set) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
    pool.shards.each do |shard|
      ssl = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
      allow(ssl).to receive(:write)
      shard.instance_variable_set(:@ssl_socket, ssl)
    end
  end

  it "builds N parametrised shards on the capture queue without their own command listener" do
    expect(pool.shards.size).to eq(3)
    pool.shards.each_with_index do |shard, i|
      expect(shard.max_channels).to eq(5)
      expect(shard.label).to eq("IrcCapture[#{i}]")
      expect(shard.instance_variable_get(:@queue_key)).to eq(Farm::CaptureSet::QUEUE_KEY)
      expect(shard.instance_variable_get(:@commands_channel)).to be_nil
      expect(shard.instance_variable_get(:@heartbeat_key)).to eq("#{Farm::CaptureSet::POOL_HEARTBEAT_KEY}:#{i}")
      expect(shard.instance_variable_get(:@handle_signals)).to be(false)
    end
  end

  it "routes a login to a stable shard so join and part meet on the same connection" do
    idx = pool.shard_index("SomeStreamer")
    expect(pool.shard_index("somestreamer")).to eq(idx)

    expect(pool.join("SomeStreamer")).to eq(:queued)
    expect(pool.shards[idx].channels).to include("somestreamer")
    expect(pool.part("somestreamer")).to eq(:ok)
    expect(pool.shards[idx].channels).not_to include("somestreamer")
  end

  it "spreads many logins across shards" do
    logins = (1..300).map { |i| "chan#{i}" }
    used = logins.map { |l| pool.shard_index(l) }.uniq
    expect(used.sort).to eq([ 0, 1, 2 ])
  end

  it "reconcile! joins what Redis wants and parts what it no longer wants, per shard" do
    pool.join("stale")
    allow(capture_set).to receive(:logins).and_return(%w[a b c])

    joined, parted = pool.reconcile!

    expect(joined).to eq(3)
    expect(parted).to eq(1)
    all = pool.shards.flat_map { |s| s.channels.to_a }
    expect(all).to contain_exactly("a", "b", "c")
    %w[a b c].each { |l| expect(pool.shard_for(l).channels).to include(l) }
  end

  it "heartbeat payload aggregates shard state" do
    pool.join("x")
    payload = pool.heartbeat_payload

    expect(payload[:connections]).to eq(3)
    expect(payload[:channels]).to eq(1)
    expect(payload[:pending_joins]).to eq(1)
    expect(payload[:shards].size).to eq(3)
    expect(payload[:shards].sum { |s| s[:channels] }).to eq(1)
  end

  it "handles join/part commands from the pool channel" do
    pool.send(:handle_command, { action: "join", channel_login: "cmdchan" }.to_json)
    expect(pool.shard_for("cmdchan").channels).to include("cmdchan")

    pool.send(:handle_command, { action: "part", channel_login: "cmdchan" }.to_json)
    expect(pool.shard_for("cmdchan").channels).not_to include("cmdchan")

    expect(Rails.logger).to receive(:warn).with(/unknown command/)
    pool.send(:handle_command, { action: "nope", channel_login: "x" }.to_json)
  end

  it "rejects a pool with no connections" do
    expect { described_class.new(connections: 0, max_per_conn: 5, capture_set: capture_set) }.to raise_error(ArgumentError)
  end
end
