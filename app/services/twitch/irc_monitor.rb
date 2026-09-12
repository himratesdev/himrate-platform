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
    # Single anon connection holds the live monitored set. Capacity raised across releases:
    # 100→300 (TASK-251.5) when detector's 168+ live channels thrashed at 100. BUG-251.29
    # (2026-05-29) raised 300→1000 default: justcooman live-subscribe reproduce showed
    # capacity at 240 active streams + queue → silently rejected new JOIN commands. Twitch
    # IRC has no documented per-connection channel cap and community libs (e.g. tmi.js,
    # Twitch DropsMiner) report stable behavior at 1000+. ENV override for emergency tuning.
    MAX_CHANNELS = ENV.fetch("IRC_MAX_CHANNELS", "1000").to_i
    # BUG-251.29: bumped 20→40 in-flight (kept 30s window) to keep up with bigger MAX_CHANNELS
    # — drain rate now ~80 JOINs/min vs ~40 previously. Twitch tolerates ~50 JOIN/30s on
    # anon connections.
    JOIN_THROTTLE_LIMIT = ENV.fetch("IRC_JOIN_THROTTLE_LIMIT", "40").to_i
    # Window is ENV-tunable too (CR fix-iter-1 S1): the budget is spent as ONE burst per window, so
    # "60/30s" is a 60-JOIN spike every 30s — 3× the documented 20/10s peak. The capture role sets
    # 20/10s to reproduce exactly the shape DSV P5 proved acked; legacy `irc` keeps 40/30s.
    JOIN_THROTTLE_WINDOW = ENV.fetch("IRC_JOIN_THROTTLE_WINDOW", "30").to_i # seconds
    # BUG T-F1 live-verify 2026-09-05 (Notion BUG 3d283837…): Twitch silently IGNORES JOINs once a
    # connection sustains a high JOIN rate (200/30s: ~60% of a 600-channel capture shard never
    # joined — no NOTICE, no error, ROOMSTATE never arrived) and nothing here noticed, because
    # @channels is DESIRED state, not ACKNOWLEDGED state. Twitch acknowledges a JOIN with the
    # channel's ROOMSTATE (twitch.tv/commands cap), so that is the ack we track: a JOIN without
    # ROOMSTATE within JOIN_ACK_TIMEOUT is re-sent (sharing the throttle budget) up to
    # JOIN_MAX_ATTEMPTS; after that the channel is parked (suspended/renamed channels never answer)
    # and re-armed after JOIN_GAVE_UP_COOLDOWN so a transient drop still heals on its own.
    JOIN_ACK_TIMEOUT = ENV.fetch("IRC_JOIN_ACK_TIMEOUT", "60").to_i       # seconds
    JOIN_MAX_ATTEMPTS = ENV.fetch("IRC_JOIN_MAX_ATTEMPTS", "5").to_i
    JOIN_GAVE_UP_COOLDOWN = ENV.fetch("IRC_JOIN_GAVE_UP_COOLDOWN", "900").to_i # seconds
    REDIS_QUEUE_KEY = "irc:chat_messages"
    REDIS_COMMANDS_CHANNEL = "irc:commands"
    REDIS_HEARTBEAT_KEY = "irc:heartbeat"
    BACKOFF_BASE = 1             # seconds
    BACKOFF_MAX = 30             # seconds
    PING_INTERVAL = 270          # 4.5 min (Twitch expects response within 5 min)
    PING_TIMEOUT = 10            # seconds to wait for PONG after self-initiated PING
    STALE_CHANNEL_HOURS = 6      # auto-PART if no stream.offline received
    # Phase 2 G2 CR iter-1 M5-2: `read_line` fires ~1Hz; without throttling a sustained transient
    # error stream would overrun sentry-ruby's default 100-breadcrumb buffer in ~100s. Emit a
    # Sentry capture_message (with fingerprint per error class) only every Nth cumulative error so
    # alerts consolidate into a single Sentry issue per class and stay actionable rather than
    # storm-rolling.
    BREADCRUMB_THROTTLE_N = ENV.fetch("IRC_READ_ERROR_SENTRY_THROTTLE", "100").to_i

    class Error < StandardError; end

    attr_reader :channels, :pending_joins, :max_channels, :label
    attr_writer :on_periodic_check

    # EPIC FARM T-F1: the monitor is parametrised so the same TLS/JOIN/reconnect machinery can run
    # as one shard of the farm's capture pool (Farm::CaptureIrcPool): its own Redis queue, heartbeat
    # key and capacity, `commands_channel: nil` to skip the per-connection pub/sub listener (the pool
    # routes join/part to shards itself) and `handle_signals: false` so eight shards don't each
    # overwrite the process-wide SIGTERM trap (the pool owns shutdown). Defaults = the legacy single
    # bot-detection monitor (bin/irc_monitor) — that path is byte-for-byte unchanged in behaviour.
    def initialize(queue_key: REDIS_QUEUE_KEY, commands_channel: REDIS_COMMANDS_CHANNEL,
                   heartbeat_key: REDIS_HEARTBEAT_KEY, max_channels: MAX_CHANNELS,
                   handle_signals: true, label: "IrcMonitor")
      @queue_key = queue_key
      @commands_channel = commands_channel
      @heartbeat_key = heartbeat_key
      @max_channels = max_channels
      @handle_signals = handle_signals
      @label = label
      @channels = Set.new
      @pending_joins = []
      @joined = Set.new        # logins whose JOIN Twitch acknowledged (ROOMSTATE) on THIS connection
      @ack_pending = {}        # login => { sent_at:, attempts: } — JOIN sent, ROOMSTATE not yet seen
      @join_gave_up = {}       # login => gave_up_at — JOIN_MAX_ATTEMPTS exhausted, re-armed after cooldown
      @join_mutex = Mutex.new
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
      @on_periodic_check = nil
    end

    # Start the IRC monitor loop. Blocks until stop is called.
    def start
      @running = true
      setup_signal_handlers if @handle_signals
      start_command_listener if @commands_channel

      Rails.logger.info("#{label}: starting")
      connect_and_listen
    rescue StandardError => e
      Rails.logger.error("#{label}: fatal error (#{e.class}: #{e.message})")
      raise
    ensure
      cleanup
    end

    # Graceful shutdown.
    def stop
      Rails.logger.info("#{label}: stopping gracefully")
      @running = false
      part_all_channels
      close_connection
    end

    # Subscribe to a channel: record desired state + enqueue a JOIN. The actual JOIN is
    # sent by process_pending_joins from the listen loop (throttled, non-blocking) so a
    # burst of subscribe calls never blocks the reader (TASK-251.5).
    def subscribe(channel_login)
      login = channel_login.to_s.downcase.delete_prefix("#")
      result, current_size = @join_mutex.synchronize do
        if @channels.include?(login)
          [ :already_joined, @channels.size ]
        elsif @channels.size >= @max_channels
          [ :capacity_full, @channels.size ]
        else
          @channels.add(login)
          @pending_joins << login unless @pending_joins.include?(login)
          [ :queued, @channels.size ]
        end
      end
      # BUG-251.29: verbose log so capacity issues surface in logs instead of silent failures.
      case result
      when :capacity_full
        Rails.logger.warn("#{label}: subscribe(#{login}) -> capacity_full (#{current_size}/#{@max_channels})")
      when :queued
        Rails.logger.info("#{label}: subscribe(#{login}) -> queued (#{current_size}/#{@max_channels})")
      end
      result
    end

    # Unsubscribe from a channel (PART). Also cancels a pending JOIN if not yet sent.
    def unsubscribe(channel_login)
      login = channel_login.to_s.downcase.delete_prefix("#")
      was_joined = @join_mutex.synchronize do
        @pending_joins.delete(login)
        @joined.delete(login)
        @ack_pending.delete(login)
        @join_gave_up.delete(login)
        @channels.delete?(login)
      end
      return :not_joined unless was_joined

      send_raw("PART ##{login}")
      Rails.logger.info("#{label}: PART ##{login} (#{@channels.size}/#{@max_channels})")
      :ok
    end

    def connected?
      !@ssl_socket.nil? && !@ssl_socket.closed?
    end

    # Consistent copy of the desired-channel set for readers on other threads (the capture pool's
    # reconcile runs while the command thread may be mutating @channels — CR iter-1 N4).
    def channels_snapshot
      @join_mutex.synchronize { @channels.dup }
    end

    # Acknowledged-join accounting (heartbeat + pool observability). joined ⊆ channels; a channel
    # is in exactly one of: joined / ack_pending (JOIN in flight) / pending_joins (not yet sent) /
    # join_gave_up (parked) — or in none of them if it never got a JOIN yet on this connection.
    # One consistent snapshot under one lock (CR fix-iter-1 N3): joined + unacked never exceed
    # channels within a single reading, which is what a heartbeat-based gate compares.
    def join_stats
      @join_mutex.synchronize do
        { channels: @channels.size, joined: @joined.size, unacked: @ack_pending.size, gave_up: @join_gave_up.size }
      end
    end

    def joined_count = join_stats[:joined]
    def unacked_count = join_stats[:unacked]
    def gave_up_count = join_stats[:gave_up]

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
          Rails.logger.warn("#{label}: connection lost (#{e.class}: #{e.message})")
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
      Rails.logger.info("#{label}: TLS connected to #{IRC_HOST}:#{IRC_PORT}")
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

      Rails.logger.info("#{label}: authenticated as justinfan")
    end

    # On (re)connect, re-queue the desired channel set so process_pending_joins re-sends
    # JOINs gradually from the listen loop — never a blocking synchronous rejoin.
    def rejoin_channels
      count = @join_mutex.synchronize do
        # Fresh connection: nothing is acknowledged yet, every desired channel must be re-JOINed.
        @joined.clear
        @ack_pending.clear
        @join_gave_up.clear
        @channels.each { |login| @pending_joins << login unless @pending_joins.include?(login) }
        @channels.size
      end
      Rails.logger.info("#{label}: re-queued #{count} channels for JOIN") if count.positive?
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

        # Drain queued JOINs at the throttled rate WITHOUT sleeping the reader (TASK-251.5).
        process_pending_joins

        # Periodic heartbeat for Kamal health check + optional callback
        if Time.current - @last_heartbeat_at > 30
          retry_unacked_joins
          update_heartbeat
          flush_memory_buffer
          @on_periodic_check&.call
          # BUG-251.29: if command listener thread crashed silently, restart it so we
          # don't go deaf to JOIN/PART commands. (Pool shards have no listener of their own.)
          ensure_command_listener_alive if @commands_channel
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
        Rails.logger.info("#{label}: received RECONNECT, reconnecting immediately")
        close_connection
      when "ROOMSTATE"
        # Twitch's JOIN acknowledgement — see JOIN_ACK_TIMEOUT. Still archived like any other event.
        mark_joined(parsed.channel_login)
        push_to_redis(parsed)
      when "PRIVMSG", "USERNOTICE", "CLEARCHAT", "CLEARMSG"
        push_to_redis(parsed)
      end
    end

    # === JOIN acknowledgement ===

    def mark_joined(login)
      return if login.blank?

      @join_mutex.synchronize do
        @joined.add(login) if @channels.include?(login)
        @ack_pending.delete(login)
        @join_gave_up.delete(login)
      end
    end

    def record_join_sent(login)
      @join_mutex.synchronize do
        # CR fix-iter-1 M1: a part can race the JOIN send (the mutex is released around send_raw).
        # Never track a channel that is no longer desired — `unacked` would carry a phantom forever.
        next unless @channels.include?(login)

        attempts = @ack_pending[login]&.fetch(:attempts, 0).to_i
        @ack_pending[login] = { sent_at: Time.current, attempts: attempts + 1 }
      end
    end

    # Every heartbeat tick: re-queue JOINs Twitch never acknowledged (no ROOMSTATE within
    # JOIN_ACK_TIMEOUT); park a channel after JOIN_MAX_ATTEMPTS and re-arm it after the cooldown.
    # Retries go through @pending_joins, i.e. they share the normal throttle budget. Entries for
    # channels no longer desired (lost part × JOIN race) are dropped here so state converges in one
    # tick even if the race above is lost (M1).
    def retry_unacked_joins
      now = Time.current
      retry_logins = []
      parked = []
      stale = []
      parked_total = 0
      @join_mutex.synchronize do
        @ack_pending.each do |login, meta|
          if !@channels.include?(login)
            stale << login
          elsif now - meta[:sent_at] >= JOIN_ACK_TIMEOUT
            meta[:attempts] >= JOIN_MAX_ATTEMPTS ? parked << login : retry_logins << login
          end
        end
        @join_gave_up.each do |login, gave_up_at|
          if !@channels.include?(login)
            stale << login
          elsif now - gave_up_at >= JOIN_GAVE_UP_COOLDOWN
            retry_logins << login
          end
        end
        stale.each do |login|
          @ack_pending.delete(login)
          @join_gave_up.delete(login)
        end
        parked.each do |login|
          @ack_pending.delete(login)
          @join_gave_up[login] = now
        end
        queued = @pending_joins.to_set # one O(n) build instead of O(n) per retry (N1)
        retry_logins.each do |login|
          @join_gave_up.delete(login)
          @pending_joins << login unless queued.include?(login)
        end
        parked_total = @join_gave_up.size # read under the same lock as the rest (N2)
      end
      return if retry_logins.empty? && parked.empty?

      Rails.logger.warn(
        "#{label}: JOIN ack sweep — re-queued #{retry_logins.size} unacknowledged after #{JOIN_ACK_TIMEOUT}s, " \
        "parked #{parked.size} after #{JOIN_MAX_ATTEMPTS} attempts (parked total #{parked_total})"
      )
    end

    # === Redis Queue ===

    MEMORY_BUFFER_MAX = 10_000

    def push_to_redis(parsed)
      record = @parser.to_record(parsed)
      return unless record

      payload = JSON.generate(record.merge(timestamp: serialize_time(record[:timestamp])))
      redis.lpush(@queue_key, payload)
    rescue Redis::BaseError => e
      @memory_buffer.shift if @memory_buffer.size >= MEMORY_BUFFER_MAX
      @memory_buffer << payload
      Rails.logger.warn("#{label}: Redis push failed, buffered in memory (#{@memory_buffer.size})")
    end

    # `JSON.generate` does NOT go through ActiveSupport's as_json: when the JSON gem hands it a
    # ::JSON::State, ActiveSupport's Object#to_json deliberately falls back to the gem's own
    # behaviour, which renders a Time via to_s — "2026-09-12 04:33:15 UTC", second precision. The
    # milliseconds died on this line, silently, and the damage was invisible while the timestamp
    # was our own clock anyway. Measured after switching to tmi-sent-ts: drift against Twitch's tag
    # was uniform across −984…−26 ms — the exact signature of floor-to-second, not of clock skew.
    # iso8601(3) is unambiguous about both precision and zone, which matters because Time.parse on
    # a bare "Y-m-d H:M:S.mmm" would resolve it in the drain process's local zone.
    def serialize_time(value)
      return value unless value.respond_to?(:iso8601)

      value.utc.iso8601(3)
    end

    def flush_memory_buffer
      return if @memory_buffer.empty?

      flushed = 0
      while (payload = @memory_buffer.shift)
        redis.lpush(@queue_key, payload)
        flushed += 1
      end
      Rails.logger.info("#{label}: flushed #{flushed} messages from memory buffer to Redis")
    rescue Redis::BaseError => e
      # Phase 2 G rescue audit M4: previously silent — memory buffer
      # backpressure invisible. Logger.warn (NOT capture_exception — это steady
      # state under Redis outage, не event) so ops can grep for it during incident.
      Rails.logger.warn("#{label}: Redis still unavailable during flush — #{@memory_buffer.size} messages held in memory (#{e.message})")
    end

    # === Reconnect ===

    def reconnect_with_backoff
      @reconnect_attempts += 1
      jitter = 1.0 + rand(-0.2..0.2)
      delay = [ BACKOFF_BASE * (2**(@reconnect_attempts - 1)) * jitter, BACKOFF_MAX ].min

      Rails.logger.info("#{label}: reconnecting in #{delay.round(1)}s (attempt #{@reconnect_attempts})")
      sleep(delay)
    end

    # === JOIN Queue (throttled, non-blocking) ===

    # Send up to the remaining throttle budget of queued JOINs. Called every listen_loop
    # iteration; never sleeps, so the reader keeps reading PRIVMSG / PONG / heartbeat while
    # the channel set fills gradually (TASK-251.5 — replaces the blocking throttle_join).
    def process_pending_joins
      return if @pending_joins.empty?

      join_budget.times do
        login = @join_mutex.synchronize { @pending_joins.shift }
        break unless login

        send_raw("JOIN ##{login}")
        @join_timestamps << Time.current
        record_join_sent(login)
        Rails.logger.info("#{label}: JOIN ##{login} (#{@channels.size}/#{@max_channels}, #{@pending_joins.size} pending)")
      end
    end

    # JOINs still allowed in the current throttle window (sliding JOIN_THROTTLE_WINDOW).
    def join_budget
      now = Time.current
      @join_timestamps.reject! { |t| now - t > JOIN_THROTTLE_WINDOW }
      [ JOIN_THROTTLE_LIMIT - @join_timestamps.size, 0 ].max
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
        Rails.logger.warn("#{label}: PONG timeout, forcing reconnect")
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
      Rails.logger.info("#{label}: stopped")
    end

    # === I/O ===

    def send_raw(message)
      return unless connected?

      @mutex.synchronize do
        @ssl_socket.write("#{message}\r\n")
      end
    rescue IOError, Errno::EPIPE => e
      Rails.logger.warn("#{label}: send failed (#{e.message})")
    end

    def read_line(timeout: 1)
      return nil unless connected?

      if IO.select([ @socket ], nil, nil, timeout)
        line = @ssl_socket.gets
        return nil if line.nil? # EOF = disconnected

        line.force_encoding("UTF-8")
        line.valid_encoding? ? line : nil
      end
    rescue IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      # Phase 2 G2 rescue audit M5: socket read failures previously returned nil
      # silently — caller treated as "no data" but the socket may be flaking. The
      # connection-watchdog upstairs (BUG-251.29 / health check) covers true
      # disconnects, but an intermittent SSL stall used to show up as "quiet IRC"
      # with no signal. CR iter-1 M5-1: `bin/irc_monitor` is a long-lived process
      # with no upstream `Sentry.capture_exception` path, so breadcrumbs alone
      # never reach Sentry — and `Rails.logger.debug` is suppressed at the
      # production `info` log level. Net signal was zero. CR iter-1 M5-2:
      # `read_line` fires ~1Hz from `listen_loop`, so an unthrottled emit would
      # overrun sentry-ruby's default 100-breadcrumb buffer in ~100s, polluting
      # diagnostic context for any unrelated capture.
      #
      # Fix: bump an instance-local cumulative counter on every error (cheap,
      # in-process), upgrade the log line to `warn` so it lands in Loki without
      # raising the verbosity floor past the existing `send failed` warnings,
      # and emit a Sentry `capture_message` only every BREADCRUMB_THROTTLE_N
      # errors so the alert consolidates into a single Sentry issue per
      # `error_class` (fingerprint includes class) and the breadcrumb buffer is
      # not flooded. Sentry will still flush on `capture_message` even without an
      # upstream `capture_exception`.
      @irc_read_error_counter ||= 0
      @irc_read_error_counter += 1
      Rails.logger.warn("[#{label}] read_line transient error (#{e.class}): #{e.message} (cumulative=#{@irc_read_error_counter})")
      if defined?(Sentry) && (@irc_read_error_counter % BREADCRUMB_THROTTLE_N).zero?
        Sentry.with_scope do |scope|
          scope.set_tags(irc_read_error: e.class.name.to_s)
          scope.set_fingerprint([ "irc_monitor_read_line_transient", e.class.name.to_s ])
          scope.set_context("irc_read_line", { cumulative_count: @irc_read_error_counter })
          Sentry.capture_message("IrcMonitor read_line transient errors crossed threshold", level: :warning)
        end
      end
      nil
    end

    # === Signal Handlers ===

    def setup_signal_handlers
      trap("SIGTERM") { @running = false }
      trap("SIGINT") { @running = false }
    end

    # === Redis Pub/Sub Command Listener ===
    # Allows StreamOnlineWorker/StreamOfflineWorker to send JOIN/PART commands.

    # BUG-251.29: command listener thread tracked + health-monitored so a silent crash
    # (e.g., StandardError outside Redis::BaseError) doesn't leave us deaf to JOIN commands.
    # listen_loop periodically calls #ensure_command_listener_alive to restart if dead.
    def start_command_listener
      @command_listener_thread = Thread.new do
        Rails.logger.info("#{label}: command listener thread started (tid=#{Thread.current.object_id})")
        command_redis = Redis.new(url: redis_url)
        command_redis.subscribe(@commands_channel) do |on|
          on.subscribe do |_, _|
            Rails.logger.info("#{label}: subscribed to Redis channel #{@commands_channel}")
          end
          on.message do |_channel, message|
            handle_command(message)
          end
        end
      rescue Redis::BaseError => e
        Rails.logger.error("#{label}: command listener Redis error (#{e.message}) — restarting")
        sleep(5)
        retry if @running
      rescue StandardError => e
        # BUG-251.29: previously uncaught — silent thread death left us unable to receive JOIN
        # commands. Now logged and re-raised so ensure_command_listener_alive can restart.
        Rails.logger.error("#{label}: command listener fatal #{e.class}: #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        raise
      end
    end

    def ensure_command_listener_alive
      return if @command_listener_thread&.alive?

      Rails.logger.error("#{label}: command listener thread is dead — restarting")
      start_command_listener
    end

    def handle_command(message)
      data = JSON.parse(message)
      action = data["action"]
      login = data["channel_login"]
      Rails.logger.info("#{label}: handle_command action=#{action} login=#{login}")
      case action
      when "join"
        result = subscribe(login)
        Rails.logger.info("#{label}: handle_command join(#{login}) -> #{result}")
      when "part"
        result = unsubscribe(login)
        Rails.logger.info("#{label}: handle_command part(#{login}) -> #{result}")
      else
        Rails.logger.warn("#{label}: handle_command unknown action=#{action}")
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("#{label}: invalid command (#{e.message})")
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
      stats = join_stats
      redis.setex(@heartbeat_key, 60, {
        connected: connected?,
        channels: stats[:channels],
        pending_joins: @pending_joins.size,
        joined: stats[:joined],
        unacked: stats[:unacked],
        join_gave_up: stats[:gave_up],
        last_message_at: @last_message_at.iso8601,
        uptime_seconds: (Time.current - @started_at).to_i
      }.to_json)
    rescue Redis::BaseError => e
      # Phase 2 G rescue audit M4: heartbeat write failure used to be silent —
      # health checks see stale `connected: true` indefinitely. Logger.debug (not
      # warn — heartbeat runs every cycle, would spam under Redis outage; the
      # message-flush rescue above already surfaces the broader Redis state).
      Rails.logger.debug("#{label}: heartbeat write failed (#{e.message})")
    end
  end
end
