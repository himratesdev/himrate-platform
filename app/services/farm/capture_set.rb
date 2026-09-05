# frozen_string_literal: true

module Farm
  # EPIC FARM T-F1: the Redis-backed "desired set" of channels the capture IRC pool must be in.
  #
  # One hash `farm:capture:set` — login => JSON {game_id, first_seen_at, last_seen_at, misses}.
  # CaptureSetSyncWorker reconciles it against Helix every cycle and publishes join/part commands
  # on `farm:capture:commands`; bin/irc_capture (CaptureIrcPool) applies the commands live and
  # re-reads the whole hash on boot / periodic reconcile, so a missed pub/sub message can never
  # leave a channel joined-but-forgotten (the BUG-251.29 leak pattern).
  #
  # Debounce: a channel leaves the set only after OFFLINE_MISS_THRESHOLD consecutive sweeps in
  # which its category was FULLY paged and it was absent — the same 3-miss rule as
  # MonitoredLiveDetectorWorker. Categories whose Helix paging failed mid-way are "no information
  # this cycle": their channels neither gain misses nor get parted (BUG-251.19 semantics).
  class CaptureSet
    SET_KEY = "farm:capture:set"
    COMMANDS_CHANNEL = "farm:capture:commands"
    QUEUE_KEY = "farm:capture:chat_messages"
    POOL_HEARTBEAT_KEY = "farm:capture:heartbeat"
    OFFLINE_MISS_THRESHOLD = 3

    Stats = Struct.new(:joined, :parted, :kept, :skipped_incomplete, keyword_init: true)

    def initialize(redis: nil)
      @redis = redis
    end

    # {login => {"game_id"=>..., "misses"=>n, ...}}
    def entries
      redis.hgetall(SET_KEY).transform_values { |v| JSON.parse(v) }
    end

    def logins
      redis.hkeys(SET_KEY)
    end

    # login => game_id (for the drain worker's per-batch enrichment; one HGETALL per batch).
    def game_ids
      entries.transform_values { |e| e["game_id"].to_s }
    end

    def pool_heartbeat
      raw = redis.get(POOL_HEARTBEAT_KEY)
      raw && JSON.parse(raw)
    end

    # live: {login => game_id} observed this cycle across all categories that paged COMPLETELY.
    # complete_game_ids: categories whose paging finished (a failed page → category incomplete).
    # excluded: logins already held by the bot-detection IRC (monitored + live) — never duplicated here.
    def sync(live:, complete_game_ids:, excluded: Set.new)
      now = Time.current.iso8601
      current = entries
      stats = Stats.new(joined: 0, parted: 0, kept: 0, skipped_incomplete: 0)

      live.each do |login, game_id|
        next if excluded.include?(login)

        if (entry = current[login])
          redis.hset(SET_KEY, login, entry.merge("game_id" => game_id, "last_seen_at" => now, "misses" => 0).to_json)
          stats.kept += 1
        else
          redis.hset(SET_KEY, login, { "game_id" => game_id, "first_seen_at" => now, "last_seen_at" => now, "misses" => 0 }.to_json)
          publish("join", login)
          stats.joined += 1
        end
      end

      current.each do |login, entry|
        next if live.key?(login) && !excluded.include?(login)
        unless complete_game_ids.include?(entry["game_id"].to_s)
          stats.skipped_incomplete += 1
          next
        end

        misses = entry["misses"].to_i + 1
        if misses >= OFFLINE_MISS_THRESHOLD || excluded.include?(login)
          redis.hdel(SET_KEY, login)
          publish("part", login)
          stats.parted += 1
        else
          redis.hset(SET_KEY, login, entry.merge("misses" => misses).to_json)
        end
      end

      stats
    end

    def publish(action, login)
      redis.publish(COMMANDS_CHANNEL, { action: action, channel_login: login }.to_json)
    end

    private

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
