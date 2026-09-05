# frozen_string_literal: true

require "rails_helper"

# BUG T-F1 2026-09-05: Twitch silently drops JOINs under a sustained high JOIN rate; the monitor must
# track acknowledgement (ROOMSTATE) and re-send what was never acknowledged.
RSpec.describe Twitch::IrcMonitor, "JOIN acknowledgement" do
  let(:monitor) { described_class.new(label: "Shard") }
  let(:ssl_socket) { instance_double(OpenSSL::SSL::SSLSocket, closed?: false) }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
    allow(ssl_socket).to receive(:write)
    monitor.instance_variable_set(:@ssl_socket, ssl_socket)
    allow(monitor).to receive(:push_to_redis)
  end

  def roomstate(login)
    "@emote-only=0;followers-only=-1;r9k=0;room-id=1;slow=0;subs-only=0 :tmi.twitch.tv ROOMSTATE ##{login}"
  end

  def age_pending(login, seconds)
    monitor.instance_variable_get(:@ack_pending)[login][:sent_at] = Time.current - seconds
  end

  it "counts a sent JOIN as unacknowledged until the channel's ROOMSTATE arrives" do
    monitor.subscribe("xqc")
    monitor.send(:process_pending_joins)

    expect(monitor.unacked_count).to eq(1)
    expect(monitor.joined_count).to eq(0)

    monitor.send(:process_line, roomstate("xqc"))

    expect(monitor.unacked_count).to eq(0)
    expect(monitor.joined_count).to eq(1)
    expect(monitor).to have_received(:push_to_redis) # ROOMSTATE is still archived
  end

  it "re-queues an unacknowledged JOIN after JOIN_ACK_TIMEOUT (shares the throttle budget)" do
    monitor.subscribe("silent")
    monitor.send(:process_pending_joins)
    expect(monitor.pending_joins).to be_empty

    monitor.send(:retry_unacked_joins) # too early → nothing
    expect(monitor.pending_joins).to be_empty

    age_pending("silent", described_class::JOIN_ACK_TIMEOUT + 1)
    expect(Rails.logger).to receive(:warn).with(/re-queued 1 unacknowledged/)
    monitor.send(:retry_unacked_joins)

    expect(monitor.pending_joins).to eq([ "silent" ])
    monitor.send(:process_pending_joins)
    expect(ssl_socket).to have_received(:write).with("JOIN #silent\r\n").twice
    expect(monitor.instance_variable_get(:@ack_pending)["silent"][:attempts]).to eq(2)
  end

  it "parks a channel after JOIN_MAX_ATTEMPTS and re-arms it after the cooldown" do
    monitor.subscribe("dead")
    allow(Rails.logger).to receive(:warn)
    described_class::JOIN_MAX_ATTEMPTS.times do
      monitor.send(:process_pending_joins)
      age_pending("dead", described_class::JOIN_ACK_TIMEOUT + 1)
      monitor.send(:retry_unacked_joins)
    end

    expect(monitor.gave_up_count).to eq(1)
    expect(monitor.unacked_count).to eq(0)
    expect(monitor.pending_joins).to be_empty
    expect(monitor.channels).to include("dead") # still desired — visible as parked in the heartbeat

    monitor.instance_variable_get(:@join_gave_up)["dead"] = Time.current - described_class::JOIN_GAVE_UP_COOLDOWN - 1
    monitor.send(:retry_unacked_joins)

    expect(monitor.gave_up_count).to eq(0)
    expect(monitor.pending_joins).to eq([ "dead" ])
  end

  it "unsubscribe clears every tracking bucket; reconnect resets acknowledgements" do
    monitor.subscribe("a")
    monitor.subscribe("b")
    monitor.send(:process_pending_joins)
    monitor.send(:process_line, roomstate("a"))

    expect(monitor.unsubscribe("a")).to eq(:ok)
    expect(monitor.joined_count).to eq(0)
    expect(monitor.unacked_count).to eq(1) # b still in flight

    monitor.send(:rejoin_channels) # fresh connection
    expect(monitor.unacked_count).to eq(0)
    expect(monitor.joined_count).to eq(0)
    expect(monitor.pending_joins).to eq([ "b" ])
  end

  it "ignores a ROOMSTATE for a channel we no longer want" do
    monitor.send(:process_line, roomstate("stranger"))
    expect(monitor.joined_count).to eq(0)
  end

  it "exposes joined / unacked / join_gave_up in the heartbeat" do
    redis = instance_double(Redis)
    allow(monitor).to receive(:redis).and_return(redis)
    monitor.subscribe("x")
    monitor.send(:process_pending_joins)

    expect(redis).to receive(:setex) do |_key, _ttl, json|
      payload = JSON.parse(json)
      expect(payload).to include("joined" => 0, "unacked" => 1, "join_gave_up" => 0)
    end
    monitor.send(:update_heartbeat)
  end
end
