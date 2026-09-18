# frozen_string_literal: true

require "socket"
require "openssl"
require "websocket/driver"
require "json"
require "securerandom"

module Twitch
  # WS2: Twitch Hermes realtime viewcount ingest.
  #
  # Hermes (wss://hermes.twitch.tv/v1) is Twitch's undocumented PubSub replacement. The topic
  # `video-playback-by-id.<numeric_channel_id>` pushes the authoritative realtime viewcount
  # (~every 30s) with `collaboration_viewers`/`costream_viewers` for shared-chat/costreams.
  # Reversed 2026-09-17 (see verivio-clode _tasks/TWITCH-DEEP-RE/W3-HERMES-TOPICS.md); the raw-WS
  # anonymous subscribe was proven with captures/hermes-raw-ws-proof.mjs.
  #
  # Mirrors Twitch::IrcMonitor's shape (single blocking #start with reconnect/backoff, parametrised,
  # signal-agnostic), but speaks WebSocket via websocket-driver (an ActionCable transitive dep — no
  # new gem) over a raw TLS socket. Zero business logic here: emits (channel_id, payload) to
  # #on_viewcount; the caller (bin/hermes_monitor) resolves the Stream and writes the snapshot.
  class HermesWebsocket
    HOST = "hermes.twitch.tv"
    PORT = 443
    # Anonymous: the web Client-ID in the query string, no auth. Confirmed working logged-out.
    URL = "wss://#{HOST}/v1?clientId=kimne78kx3ncx6brgo4mv6wki5h1ko"

    BACKOFF_BASE = 1
    BACKOFF_MAX = 30
    READ_TIMEOUT = 1        # IO.select slice; also the periodic-check cadence
    HEARTBEAT_KEY = "hermes:heartbeat"
    HEARTBEAT_TTL = 120

    attr_accessor :on_viewcount, :on_periodic_check

    def initialize(heartbeat_key: HEARTBEAT_KEY, label: "Hermes")
      @channel_ids = []
      @heartbeat_key = heartbeat_key
      @label = label
      @running = false
      @sub_to_channel = {} # inner subscribe id -> channel_id
      @reconnect_attempts = 0
    end

    # Register a numeric Twitch channel id to receive viewcount for. Call before #start.
    def subscribe(channel_id)
      id = channel_id.to_s
      @channel_ids << id unless @channel_ids.include?(id)
    end

    def start
      @running = true
      connect_and_listen while @running
    ensure
      close_socket
    end

    def stop
      @running = false
      close_socket
    end

    private

    def connect_and_listen
      open_socket
      @driver = WebSocket::Driver.client(self)
      wire_driver
      @driver.start
      @reconnect_attempts = 0
      listen_loop
    rescue IOError, OpenSSL::SSL::SSLError, Errno::ECONNRESET, Errno::EPIPE,
           Errno::ETIMEDOUT, Errno::ECONNREFUSED, SocketError => e
      Rails.logger.warn("#{@label}: connection error (#{e.class}: #{e.message})")
      reconnect_with_backoff if @running
    ensure
      close_socket
    end

    def open_socket
      tcp = TCPSocket.new(HOST, PORT)
      ctx = OpenSSL::SSL::SSLContext.new
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, ctx)
      ssl.hostname = HOST # SNI — Twitch edge rejects handshakes without it
      ssl.sync_close = true
      ssl.connect
      @ssl = ssl
    end

    # websocket-driver client protocol: the driver calls #url and #write(bytes) on us.
    def url
      URL
    end

    def write(data)
      @ssl.write(data)
    end

    def wire_driver
      @driver.on(:open) { subscribe_all }
      @driver.on(:message) { |event| handle_frame(event.data) }
      @driver.on(:close) do |event|
        Rails.logger.info("#{@label}: ws closed (#{event.code} #{event.reason})")
      end
      @driver.on(:error) { |event| Rails.logger.warn("#{@label}: ws error #{event.message}") }
    end

    def subscribe_all
      @channel_ids.each do |cid|
        sub_id = SecureRandom.alphanumeric(21)
        @sub_to_channel[sub_id] = cid
        @driver.text(JSON.generate(
          type: "subscribe",
          id: SecureRandom.alphanumeric(21),
          subscribe: { id: sub_id, type: "pubsub", pubsub: { topic: "video-playback-by-id.#{cid}" } },
          timestamp: Time.now.utc.iso8601
        ))
      end
      Rails.logger.info("#{@label}: subscribed #{@channel_ids.size} channels")
    end

    def listen_loop
      last_periodic = Time.current
      while @running
        ready = IO.select([ @ssl ], nil, nil, READ_TIMEOUT)
        if ready
          chunk = read_available
          break if chunk.nil? # peer closed
          @driver.parse(chunk) unless chunk.empty?
        end
        if Time.current - last_periodic >= 30
          last_periodic = Time.current
          write_heartbeat
          @on_periodic_check&.call
        end
      end
    end

    def read_available
      @ssl.read_nonblock(16_384)
    rescue IO::WaitReadable
      ""
    rescue EOFError
      nil
    end

    def handle_frame(raw)
      msg = JSON.parse(raw)
      return unless msg["type"] == "notification"

      inner = msg.dig("notification", "pubsub")
      payload = inner.is_a?(String) ? JSON.parse(inner) : inner
      return unless payload.is_a?(Hash) && payload["type"] == "viewcount"

      sub_id = msg.dig("notification", "subscription", "id")
      channel_id = @sub_to_channel[sub_id]
      return unless channel_id

      @on_viewcount&.call(channel_id, payload)
    rescue JSON::ParserError => e
      Rails.logger.debug("#{@label}: unparseable frame (#{e.message})")
    end

    def write_heartbeat
      redis.setex(@heartbeat_key, HEARTBEAT_TTL, {
        channels: @channel_ids.size,
        pid: Process.pid,
        at: Time.current.iso8601
      }.to_json)
    rescue Redis::BaseError => e
      Rails.logger.warn("#{@label}: heartbeat write failed (#{e.message})")
    end

    def reconnect_with_backoff
      @reconnect_attempts += 1
      delay = [ BACKOFF_BASE * (2**(@reconnect_attempts - 1)), BACKOFF_MAX ].min
      delay += rand(0.0..1.0) # jitter
      Rails.logger.info("#{@label}: reconnecting in #{delay.round(1)}s (attempt #{@reconnect_attempts})")
      sleep(delay)
    end

    def close_socket
      @driver&.close rescue nil
      @ssl&.close rescue nil
      @ssl = nil
      @driver = nil
      @sub_to_channel = {}
    end

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
