# frozen_string_literal: true

# TASK-024: Twitch IRC Chat Monitor.
# Connects to Twitch IRC via raw TLS (ADR: zero gem dependencies).
# Parses PRIVMSG, USERNOTICE, ROOMSTATE, CLEARCHAT/CLEARMSG.
# Pushes parsed messages to Redis list for ChatMessageWorker batch insert.
#
# Lifecycle: runs as separate process (Kamal accessory) via bin/irc_monitor.
# Communication with Sidekiq workers via Redis pub/sub (irc:commands channel).

require "socket"
require "openssl"

module Twitch
  class IrcMonitor
    IRC_HOST = "irc.chat.twitch.tv"
    IRC_PORT = 6697
    MAX_CHANNELS = 100
    JOIN_THROTTLE_LIMIT = 20     # max JOINs per throttle window
    JOIN_THROTTLE_WINDOW = 30    # seconds
    REDIS_QUEUE_KEY = "irc:chat_messages"
    REDIS_COMMANDS_CHANNEL = "irc:commands"
    REDIS_HEARTBEAT_KEY = "irc:heartbeat"
    BACKOFF_BASE = 1             # seconds
    BACKOFF_MAX = 30             # seconds
    PING_INTERVAL = 270          # 4.5 min (Twitch expects response within 5 min)
    PING_TIMEOUT = 10            # seconds to wait for PONG after self-initiated PING
    STALE_CHANNEL_HOURS = 6      # auto-PART if no stream.offline received

    class Error < StandardError; end

    attr_reader :channels

    def initialize
      @channels = Set.new
      @mutex = Monitor.new
      @socket = nil
      @ssl_socket = nil
      @running = false
      @reconnect_attempts = 0
      @parser = IrcParser.new
      @join_timestamps = []
      @last_message_at = Time.current
      @last_heartbeat_at = Time.at(0)
      @started_at = Time.current
      @awaiting_pong = false
      @memory_buffer = []
    end

    # Start the IRC monitor loop. Blocks until stop is called.
    def start
      @running = true
      setup_signal_handlers
      start_command_listener

      Rails.logger.info("IrcMonitor: starting")
      connect_and_listen
    rescue StandardError => e
      Rails.logger.error("IrcMonitor: fatal error (#{e.class}: #{e.message})")
      raise
    ensure
      cleanup
    end

    # Graceful shutdown.
    def stop
      Rails.logger.info("IrcMonitor: stopping gracefully")
      @running = false
      part_all_channels
      close_connection
    end

    # Subscribe to a channel (JOIN).
    def subscribe(channel_login)
      login = channel_login.to_s.downcase.delete_prefix("#")
      return :already_joined if @channels.include?(login)

      @mutex.synchronize do
        return :capacity_full if @channels.size >= MAX_CHANNELS

        throttle_join
        send_raw("JOIN ##{login}")
        @channels.add(login)
        Rails.logger.info("IrcMonitor: JOIN ##{login} (#{@channels.size}/#{MAX_CHANNELS})")
        :ok
      end
    end

    # Unsubscribe from a channel (PART).
    def unsubscribe(channel_login)
      login = channel_login.to_s.downcase.delete_prefix("#")
      return :not_joined unless @channels.include?(login)

      @mutex.synchronize do
        send_raw("PART ##{login}")
        @channels.delete(login)
        Rails.logger.info("IrcMonitor: PART ##{login} (#{@channels.size}/#{MAX_CHANNELS})")
        :ok
      end
    end

    def connected?
      !@ssl_socket.nil? && !@ssl_socket.closed?
    end

    private

    # === Connection ===

    def connect_and_listen
      while @running
        begin
          connect
          authenticate
          rejoin_channels
          listen_loop
        rescue IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::ETIMEDOUT,
               OpenSSL::SSL::SSLError => e
          Rails.logger.warn("IrcMonitor: connection lost (#{e.class}: #{e.message})")
          close_connection
          reconnect_with_backoff if @running
        end
      end
    end

    def connect
      tcp_socket = TCPSocket.new(IRC_HOST, IRC_PORT)
      tcp_socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)

      ssl_context = OpenSSL::SSL::SSLContext.new
      ssl_context.min_version = OpenSSL::SSL::TLS1_2_VERSION
      ssl_context.verify_mode = OpenSSL::SSL::VERIFY_PEER
      ssl_context.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)

      @ssl_socket = OpenSSL::SSL::SSLSocket.new(tcp_socket, ssl_context)
      @ssl_socket.hostname = IRC_HOST
      @ssl_socket.connect
      @socket = tcp_socket

      @reconnect_attempts = 0
      @last_message_at = Time.current
      Rails.logger.info("IrcMonitor: TLS connected to #{IRC_HOST}:#{IRC_PORT}")
    end

    def authenticate
      # membership capability omitted: deprecated for large channels, generates
      # excessive JOIN/PART traffic. Viewer lists via GQL CommunityTab (TASK-022).
      send_raw("CAP REQ :twitch.tv/tags twitch.tv/commands")
      send_raw("PASS SCHMOOPIIE")
      send_raw("NICK justinfan#{rand(1000..9999)}")

      # Wait for MOTD end (376) or welcome
      deadline = Time.current + 10
      while Time.current < deadline
        line = read_line(timeout: 5)
        break if line&.include?("376") || line&.include?("Welcome")
      end

      Rails.logger.info("IrcMonitor: authenticated as justinfan")
    end

    def rejoin_channels
      channels_copy = @channels.to_a
      channels_copy.each do |login|
        throttle_join
        send_raw("JOIN ##{login}")
      end
      Rails.logger.info("IrcMonitor: re-joined #{channels_copy.size} channels") if channels_copy.any?
    end

    # === Main Loop ===

    def listen_loop
      while @running && connected?
        check_ping_timeout
        line = read_line(timeout: 1)

        if line
          @last_message_at = Time.current
          @awaiting_pong = false if line.include?("PONG")
          process_line(line)
        else
          send_keepalive_ping if Time.current - @last_message_at > PING_INTERVAL
        end

        # Periodic heartbeat for Kamal health check
        if Time.current - @last_heartbeat_at > 30
          update_heartbeat
          flush_memory_buffer
          @last_heartbeat_at = Time.current
        end
      end
    end

    def process_line(line)
      parsed = @parser.parse(line)
      return unless parsed

      case parsed.command
      when "PING"
        send_raw("PONG :#{parsed.message_text}")
      when "RECONNECT"
        Rails.logger.info("IrcMonitor: received RECONNECT, reconnecting immediately")
        close_connection
      when "PRIVMSG", "USERNOTICE", "ROOMSTATE", "CLEARCHAT", "CLEARMSG"
        push_to_redis(parsed)
      end
    end

    # === Redis Queue ===

    MEMORY_BUFFER_MAX = 10_000

    def push_to_redis(parsed)
      record = @parser.to_record(parsed)
      return unless record

      payload = JSON.generate(record)
      redis.lpush(REDIS_QUEUE_KEY, payload)
    rescue Redis::BaseError => e
      @memory_buffer.shift if @memory_buffer.size >= MEMORY_BUFFER_MAX
      @memory_buffer << payload
      Rails.logger.warn("IrcMonitor: Redis push failed, buffered in memory (#{@memory_buffer.size})")
    end

    def flush_memory_buffer
      return if @memory_buffer.empty?

      flushed = 0
      while (payload = @memory_buffer.shift)
        redis.lpush(REDIS_QUEUE_KEY, payload)
        flushed += 1
      end
      Rails.logger.info("IrcMonitor: flushed #{flushed} messages from memory buffer to Redis")
    rescue Redis::BaseError
      # Redis still down — messages stay in memory buffer for next attempt
    end

    # === Reconnect ===

    def reconnect_with_backoff
      @reconnect_attempts += 1
      jitter = 1.0 + rand(-0.2..0.2)
      delay = [ BACKOFF_BASE * (2**(@reconnect_attempts - 1)) * jitter, BACKOFF_MAX ].min

      Rails.logger.info("IrcMonitor: reconnecting in #{delay.round(1)}s (attempt #{@reconnect_attempts})")
      sleep(delay)
    end

    # === JOIN Throttle ===

    def throttle_join
      now = Time.current
      @join_timestamps.reject! { |t| now - t > JOIN_THROTTLE_WINDOW }

      if @join_timestamps.size >= JOIN_THROTTLE_LIMIT
        wait = JOIN_THROTTLE_WINDOW - (now - @join_timestamps.first)
        if wait > 0
          Rails.logger.info("IrcMonitor: JOIN throttle, waiting #{wait.round(1)}s")
          sleep(wait)
        end
        @join_timestamps.reject! { |t| Time.current - t > JOIN_THROTTLE_WINDOW }
      end

      @join_timestamps << Time.current
    end

    # === Keepalive ===

    def send_keepalive_ping
      return if @awaiting_pong

      send_raw("PING :himrate")
      @awaiting_pong = true
      @ping_sent_at = Time.current
    end

    def check_ping_timeout
      return unless @awaiting_pong && @ping_sent_at

      if Time.current - @ping_sent_at > PING_TIMEOUT
        Rails.logger.warn("IrcMonitor: PONG timeout, forcing reconnect")
        @awaiting_pong = false
        close_connection
      end
    end

    # === Cleanup ===

    def part_all_channels
      @channels.each { |login| send_raw("PART ##{login}") rescue nil }
    end

    def close_connection
      @ssl_socket&.close rescue nil
      @socket&.close rescue nil
      @ssl_socket = nil
      @socket = nil
    end

    def cleanup
      close_connection
      Rails.logger.info("IrcMonitor: stopped")
    end

    # === I/O ===

    def send_raw(message)
      return unless connected?

      @mutex.synchronize do
        @ssl_socket.write("#{message}\r\n")
      end
    rescue IOError, Errno::EPIPE => e
      Rails.logger.warn("IrcMonitor: send failed (#{e.message})")
    end

    def read_line(timeout: 1)
      return nil unless connected?

      if IO.select([ @socket ], nil, nil, timeout)
        line = @ssl_socket.gets
        return nil if line.nil? # EOF = disconnected

        line.force_encoding("UTF-8")
        line.valid_encoding? ? line : nil
      end
    rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError
      nil
    end

    # === Signal Handlers ===

    def setup_signal_handlers
      trap("SIGTERM") { @running = false }
      trap("SIGINT") { @running = false }
    end

    # === Redis Pub/Sub Command Listener ===
    # Allows StreamOnlineWorker/StreamOfflineWorker to send JOIN/PART commands.

    def start_command_listener
      Thread.new do
        command_redis = Redis.new(url: redis_url)
        command_redis.subscribe(REDIS_COMMANDS_CHANNEL) do |on|
          on.message do |_channel, message|
            handle_command(message)
          end
        end
      rescue Redis::BaseError => e
        Rails.logger.error("IrcMonitor: command listener error (#{e.message})")
        sleep(5)
        retry if @running
      end
    end

    def handle_command(message)
      data = JSON.parse(message)
      case data["action"]
      when "join"
        subscribe(data["channel_login"])
      when "part"
        unsubscribe(data["channel_login"])
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("IrcMonitor: invalid command (#{e.message})")
    end

    # === Redis ===

    def redis
      @redis ||= Redis.new(url: redis_url)
    end

    def redis_url
      ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
    end

    # === Heartbeat ===

    def update_heartbeat
      redis.setex(REDIS_HEARTBEAT_KEY, 60, {
        connected: connected?,
        channels: @channels.size,
        last_message_at: @last_message_at.iso8601,
        uptime_seconds: (Time.current - @started_at).to_i
      }.to_json)
    rescue Redis::BaseError
      # Non-critical
    end
  end
end
