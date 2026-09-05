# frozen_string_literal: true

require "zlib"

module Farm
  # EPIC FARM T-F1: a pool of N anonymous Twitch IRC connections holding the farm's capture set.
  #
  # Each shard is a Twitch::IrcMonitor parametrised onto the capture queue (`farm:capture:chat_messages`)
  # with its own heartbeat key and capacity, and WITHOUT a per-connection command listener — the pool
  # owns the single `farm:capture:commands` subscriber and routes join/part to the shard chosen by
  # crc32(login) % N (stable: the same login always lands on the same shard, so a join and its later
  # part meet on one connection).
  #
  # DSV 2026-09-05 (INGEST-EXPANSION-DESIGN §6): one anon connection held 2400 channels with no cap
  # or JOIN throttle applied by Twitch; 5 parallel connections from one IP had 0 refusals. Sizing:
  # 8 shards × 1000 = 8k channels (the PUBG+CS2+Dota+JC(ru,en) set at peak) with 2.4× headroom.
  #
  # Self-healing: on boot and every RECONCILE_INTERVAL the pool re-reads the whole desired set from
  # Redis and joins/parts the difference, so a missed pub/sub command can never leave a channel
  # joined-but-forgotten (BUG-251.29 leak pattern). A shard whose thread died is restarted.
  class CaptureIrcPool
    DEFAULT_CONNECTIONS = ENV.fetch("IRC_CAPTURE_CONNECTIONS", "8").to_i
    DEFAULT_MAX_PER_CONN = ENV.fetch("IRC_CAPTURE_MAX_PER_CONN", "1000").to_i
    RECONCILE_INTERVAL = 600 # seconds
    HEARTBEAT_INTERVAL = 30  # seconds

    attr_reader :shards
    attr_writer :on_periodic_check

    def initialize(connections: DEFAULT_CONNECTIONS, max_per_conn: DEFAULT_MAX_PER_CONN, capture_set: nil)
      raise ArgumentError, "connections must be >= 1" if connections < 1

      @capture_set = capture_set || Farm::CaptureSet.new
      @shards = Array.new(connections) do |i|
        Twitch::IrcMonitor.new(
          queue_key: Farm::CaptureSet::QUEUE_KEY,
          commands_channel: nil,
          heartbeat_key: "#{Farm::CaptureSet::POOL_HEARTBEAT_KEY}:#{i}",
          max_channels: max_per_conn,
          handle_signals: false,
          label: "IrcCapture[#{i}]"
        )
      end
      @threads = []
      @running = false
      @on_periodic_check = nil
      @last_heartbeat_at = Time.at(0)
      @last_reconcile_at = Time.at(0)
      @started_at = Time.current
    end

    # Deterministic shard for a login — join and part always meet on the same connection.
    def shard_index(login)
      Zlib.crc32(login.to_s.downcase) % @shards.size
    end

    def shard_for(login)
      @shards[shard_index(login)]
    end

    def join(login)
      shard_for(login).subscribe(login)
    end

    def part(login)
      shard_for(login).unsubscribe(login)
    end

    # Blocks until #stop. Loads the desired set, starts one thread per shard, listens for commands,
    # and runs the heartbeat / reconcile / liveness loop.
    def start
      @running = true
      trap("SIGTERM") { @running = false }
      trap("SIGINT") { @running = false }

      reconcile!
      @threads = @shards.map { |shard| spawn_shard(shard) }
      start_command_listener
      Rails.logger.info("IrcCapture: pool started (#{@shards.size} shards, #{desired_logins.size} channels)")

      supervise_loop
    ensure
      stop_shards
      Rails.logger.info("IrcCapture: pool stopped")
    end

    def stop
      @running = false
    end

    # Bring every shard's channel set in line with the Redis desired set. Returns [joined, parted].
    def reconcile!
      desired = desired_logins
      joined = 0
      parted = 0
      @shards.each_with_index do |shard, i|
        wanted = desired.select { |login| shard_index(login) == i }.to_set
        (shard.channels.to_set - wanted).each { |login| shard.unsubscribe(login); parted += 1 }
        (wanted - shard.channels.to_set).each { |login| shard.subscribe(login); joined += 1 }
      end
      Rails.logger.info("IrcCapture: reconcile joined=#{joined} parted=#{parted} desired=#{desired.size}") if joined.positive? || parted.positive?
      [ joined, parted ]
    end

    def heartbeat_payload
      {
        connections: @shards.size,
        channels: @shards.sum { |s| s.channels.size },
        pending_joins: @shards.sum { |s| s.pending_joins.size },
        shards: @shards.map { |s| { channels: s.channels.size, pending: s.pending_joins.size, connected: s.connected? } },
        uptime_seconds: (Time.current - @started_at).to_i,
        at: Time.current.iso8601
      }
    end

    private

    def desired_logins
      @capture_set.logins.map(&:downcase).uniq
    end

    def spawn_shard(shard)
      Thread.new do
        shard.start
      rescue StandardError => e
        Rails.logger.error("IrcCapture: shard #{shard.label} died (#{e.class}: #{e.message})")
      end
    end

    def supervise_loop
      while @running
        sleep 1
        now = Time.current
        if now - @last_heartbeat_at > HEARTBEAT_INTERVAL
          write_heartbeat
          restart_dead_shards
          ensure_command_listener_alive
          @on_periodic_check&.call
          @last_heartbeat_at = now
        end
        if now - @last_reconcile_at > RECONCILE_INTERVAL
          safely("reconcile") { reconcile! }
          @last_reconcile_at = now
        end
      end
    end

    def restart_dead_shards
      @threads.each_with_index do |thread, i|
        next if thread.alive?

        Rails.logger.error("IrcCapture: shard #{i} thread dead — restarting (channels kept: #{@shards[i].channels.size})")
        @threads[i] = spawn_shard(@shards[i])
      end
    end

    def stop_shards
      @shards.each { |s| s.stop rescue nil }
      @threads.each { |t| t.join(5) rescue nil }
      @command_listener_thread&.kill
    end

    # One subscriber for the whole pool; join/part routed to the owning shard.
    def start_command_listener
      @command_listener_thread = Thread.new do
        command_redis = Redis.new(url: redis_url)
        command_redis.subscribe(Farm::CaptureSet::COMMANDS_CHANNEL) do |on|
          on.message { |_channel, message| handle_command(message) }
        end
      rescue Redis::BaseError => e
        Rails.logger.error("IrcCapture: command listener Redis error (#{e.message}) — restarting")
        sleep(5)
        retry if @running
      rescue StandardError => e
        Rails.logger.error("IrcCapture: command listener fatal #{e.class}: #{e.message}")
        raise
      end
    end

    def ensure_command_listener_alive
      return if @command_listener_thread&.alive?

      Rails.logger.error("IrcCapture: command listener thread is dead — restarting")
      start_command_listener
    end

    def handle_command(message)
      data = JSON.parse(message)
      login = data["channel_login"].to_s
      return if login.blank?

      case data["action"]
      when "join" then Rails.logger.info("IrcCapture: join(#{login}) -> #{join(login)}")
      when "part" then Rails.logger.info("IrcCapture: part(#{login}) -> #{part(login)}")
      else Rails.logger.warn("IrcCapture: unknown command action=#{data['action']}")
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("IrcCapture: invalid command (#{e.message})")
    end

    def write_heartbeat
      redis.setex(Farm::CaptureSet::POOL_HEARTBEAT_KEY, 120, heartbeat_payload.to_json)
    rescue Redis::BaseError => e
      Rails.logger.warn("IrcCapture: heartbeat write failed (#{e.message})")
    end

    def safely(what)
      yield
    rescue StandardError => e
      Rails.logger.error("IrcCapture: #{what} failed (#{e.class}: #{e.message})")
    end

    def redis
      @redis ||= Redis.new(url: redis_url)
    end

    def redis_url
      ENV.fetch("REDIS_URL", "redis://localhost:6379/1")
    end
  end
end
