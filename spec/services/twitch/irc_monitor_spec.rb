# frozen_string_literal: true

require "rails_helper"

RSpec.describe Twitch::IrcMonitor do
  let(:monitor) { described_class.new }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("REDIS_URL", anything).and_return("redis://localhost:6379/1")
  end

  describe "#subscribe / #unsubscribe" do
    before do
      # Mock the socket so we don't actually connect
      ssl_socket = instance_double(OpenSSL::SSL::SSLSocket, closed?: false)
      allow(ssl_socket).to receive(:write)
      monitor.instance_variable_set(:@ssl_socket, ssl_socket)
    end

    # TC-009: JOIN channel
    it "subscribes to a channel" do
      result = monitor.subscribe("xqc")

      expect(result).to eq(:ok)
      expect(monitor.channels).to include("xqc")
    end

    # TC-012: Duplicate JOIN
    it "returns :already_joined for duplicate subscribe" do
      monitor.subscribe("xqc")
      result = monitor.subscribe("xqc")

      expect(result).to eq(:already_joined)
    end

    # TC-011: Capacity full
    it "returns :capacity_full when at 100 channels" do
      100.times { |i| monitor.subscribe("channel#{i}") }

      result = monitor.subscribe("channel100")
      expect(result).to eq(:capacity_full)
      expect(monitor.channels.size).to eq(100)
    end

    # TC-010: PART channel
    it "unsubscribes from a channel" do
      monitor.subscribe("xqc")
      result = monitor.unsubscribe("xqc")

      expect(result).to eq(:ok)
      expect(monitor.channels).not_to include("xqc")
    end

    it "returns :not_joined for unsubscribe of unknown channel" do
      result = monitor.unsubscribe("unknown")
      expect(result).to eq(:not_joined)
    end

    it "normalizes channel names (lowercase, no #)" do
      monitor.subscribe("#XQC")
      expect(monitor.channels).to include("xqc")
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
