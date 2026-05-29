# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::IrcMonitor do
  let(:monitor) { described_class.new }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
  end

  describe "#subscribe / #unsubscribe (queue-based, TASK-251.5)" do
    before do
      # Mock the socket so we don't actually connect
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
      allow(ssl_socket).to receive(:write)
      monitor.instance_variable_set(:@ssl_socket, ssl_socket)
    end

    # TC-009: JOIN is queued (sent later by process_pending_joins, non-blocking)
    it "queues a channel for JOIN and records desired state" do
      result = monitor.subscribe("xqc")

      expect(result).to eq(:queued)
      expect(monitor.channels).to include("xqc")
      expect(monitor.pending_joins).to include("xqc")
    end

    # TC-012: Duplicate JOIN
    it "returns :already_joined for duplicate subscribe" do
      monitor.subscribe("xqc")
      expect(monitor.subscribe("xqc")).to eq(:already_joined)
    end

    # TC-011: Capacity full (at MAX_CHANNELS desired)
    it "returns :capacity_full at MAX_CHANNELS" do
      described_class::MAX_CHANNELS.times { |i| monitor.subscribe("channel#{i}") }

      expect(monitor.subscribe("one_too_many")).to eq(:capacity_full)
      expect(monitor.channels.size).to eq(described_class::MAX_CHANNELS)
    end

    # BUG-251.29: capacity_full now logs a warning (was silent → invisible drops in production).
    it "logs a warning when subscribe hits capacity_full (BUG-251.29)" do
      described_class::MAX_CHANNELS.times { |i| monitor.subscribe("channel#{i}") }

      expect(Rails.logger).to receive(:warn).with(/capacity_full/)
      monitor.subscribe("overflow")
    end

    # BUG-251.29: default capacity raised 300 → 1000 (single anon connection holds the live set
    # without the silent-drop pattern observed at 300 with 240+ active streams + pending queue).
    it "default MAX_CHANNELS is at least 1000 (BUG-251.29)" do
      expect(described_class::MAX_CHANNELS).to be >= 1000
    end
  end

  # BUG-251.29: handle_command logs every received command + result.
  describe "#handle_command logging (BUG-251.29)" do
    it "logs received JOIN command + result" do
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
      allow(ssl_socket).to receive(:write)
      monitor.instance_variable_set(:@ssl_socket, ssl_socket)

      expect(Rails.logger).to receive(:info).with(/handle_command action=join login=xqc/).ordered
      # subscribe inner logs ('subscribe(xqc) -> queued') + handle_command outer log
      allow(Rails.logger).to receive(:info)

      monitor.send(:handle_command, { action: "join", channel_login: "xqc" }.to_json)
    end

    it "warns on unknown action" do
      expect(Rails.logger).to receive(:warn).with(/unknown action=spam/)
      monitor.send(:handle_command, { action: "spam", channel_login: "x" }.to_json)
    end
  end

  # BUG-251.29: command_listener_alive restarts a dead thread.
  describe "#ensure_command_listener_alive (BUG-251.29)" do
    it "restarts a dead command listener thread" do
      dead_thread = instance_double(Thread, alive?: false)
      monitor.instance_variable_set(:@command_listener_thread, dead_thread)

      expect(Rails.logger).to receive(:error).with(/dead/)
      expect(monitor).to receive(:start_command_listener)

      monitor.send(:ensure_command_listener_alive)
    end

    it "no-op when listener thread is alive" do
      live_thread = instance_double(Thread, alive?: true)
      monitor.instance_variable_set(:@command_listener_thread, live_thread)

      expect(monitor).not_to receive(:start_command_listener)
      monitor.send(:ensure_command_listener_alive)
    end

    # TC-010: PART channel (drops desired state + cancels pending)
    it "unsubscribes from a channel" do
      monitor.subscribe("xqc")
      result = monitor.unsubscribe("xqc")

      expect(result).to eq(:ok)
      expect(monitor.channels).not_to include("xqc")
      expect(monitor.pending_joins).not_to include("xqc")
    end

    it "returns :not_joined for unsubscribe of unknown channel" do
      expect(monitor.unsubscribe("unknown")).to eq(:not_joined)
    end

    it "normalizes channel names (lowercase, no #)" do
      monitor.subscribe("#XQC")
      expect(monitor.channels).to include("xqc")
    end
  end

  describe "#process_pending_joins (TASK-251.5 — non-blocking throttled drain)" do
    let(:ssl_socket) { instance_double(OpenSSL::SSL::SSLSocket, closed?: false) }

    before do
      allow(ssl_socket).to receive(:write)
      monitor.instance_variable_set(:@ssl_socket, ssl_socket)
    end

    it "sends JOIN for queued channels and empties the queue" do
      monitor.subscribe("xqc")
      monitor.subscribe("pokimane")

      monitor.send(:process_pending_joins)

      expect(ssl_socket).to have_received(:write).with("JOIN #xqc\r\n")
      expect(ssl_socket).to have_received(:write).with("JOIN #pokimane\r\n")
      expect(monitor.pending_joins).to be_empty
    end

    it "sends at most JOIN_THROTTLE_LIMIT JOINs per call (no blocking sleep)" do
      (described_class::JOIN_THROTTLE_LIMIT + 5).times { |i| monitor.subscribe("ch#{i}") }

      monitor.send(:process_pending_joins)

      expect(ssl_socket).to have_received(:write).exactly(described_class::JOIN_THROTTLE_LIMIT).times
      expect(monitor.pending_joins.size).to eq(5)
    end
  end

  describe "#connected?" do
    it "returns false when no socket" do
      expect(monitor.connected?).to be false
    end

    it "returns true when socket is open" do
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
      monitor.instance_variable_set(:@ssl_socket, ssl_socket)
      expect(monitor.connected?).to be true
    end
  end
end
