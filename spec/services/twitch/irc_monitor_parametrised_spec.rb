# frozen_string_literal: true

require "rails_helper"

# EPIC FARM T-F1: the monitor can run as a pool shard with its own queue / heartbeat / capacity
# and without a per-connection command listener. Defaults must stay the legacy bin/irc_monitor.
RSpec.describe Twitch::IrcMonitor, "parametrised for Farm::CaptureIrcPool" do
  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
  end

  it "defaults are the legacy single-monitor contract" do
    m = described_class.new
    expect(m.instance_variable_get(:@queue_key)).to eq("irc:chat_messages")
    expect(m.instance_variable_get(:@commands_channel)).to eq("irc:commands")
    expect(m.instance_variable_get(:@heartbeat_key)).to eq("irc:heartbeat")
    expect(m.instance_variable_get(:@handle_signals)).to be(true)
    expect(m.max_channels).to eq(described_class::MAX_CHANNELS)
    expect(m.label).to eq("IrcMonitor")
  end

  it "honours a custom capacity" do
    m = described_class.new(max_channels: 2, label: "Shard")
    ssl = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
    allow(ssl).to receive(:write)
    m.instance_variable_set(:@ssl_socket, ssl)

    expect(m.subscribe("a")).to eq(:queued)
    expect(m.subscribe("b")).to eq(:queued)
    expect(Rails.logger).to receive(:warn).with(/Shard: subscribe\(c\) -> capacity_full \(2\/2\)/)
    expect(m.subscribe("c")).to eq(:capacity_full)
  end

  it "pushes parsed chat onto the configured queue key" do
    m = described_class.new(queue_key: "farm:capture:chat_messages")
    redis = instance_double(Redis)
    allow(m).to receive(:redis).and_return(redis)
    parsed = Twitch::IrcParser.new.parse("@id=1;display-name=U :u!u@u.tmi.twitch.tv PRIVMSG #chan :hi")

    expect(redis).to receive(:lpush).with("farm:capture:chat_messages", kind_of(String))
    m.send(:push_to_redis, parsed)
  end

  it "writes the heartbeat under the configured key" do
    m = described_class.new(heartbeat_key: "farm:capture:heartbeat:3")
    redis = instance_double(Redis)
    allow(m).to receive(:redis).and_return(redis)

    expect(redis).to receive(:setex).with("farm:capture:heartbeat:3", 60, kind_of(String))
    m.send(:update_heartbeat)
  end

  it "does not start a command listener or signal traps when configured as a shard" do
    m = described_class.new(commands_channel: nil, handle_signals: false)
    allow(m).to receive(:connect_and_listen)
    expect(m).not_to receive(:start_command_listener)
    expect(m).not_to receive(:setup_signal_handlers)

    m.start
  end
end
