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
  # Leaving the set (CR iter-1 M1/N1 — every exit path must PART, nothing may linger):
  #   1. login is now held by the bot-detection IRC (`excluded`)        → part immediately
  #   2. its category is no longer configured/enabled (`configured_game_ids`) → part immediately
  #   3. its category paged incompletely this cycle (`complete_game_ids`)   → no information, keep
  #   4. absent from a fully-paged category                              → miss; part after 3 misses
  # (3-miss debounce = the MonitoredLiveDetectorWorker rule; "incomplete = no information" is the
  # BUG-251.19 partial-batch semantics.)
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
    # configured_game_ids: every enabled category this cycle (a category outside it has been
    #   disabled/removed → its channels leave the set at once).
    # complete_game_ids: enabled categories whose paging finished (subset of configured).
    # excluded: logins already held by the bot-detection IRC (monitored + live) — never duplicated here.
    #
    # All Redis writes go out in one pipeline (CR iter-1 N3): ~6k HSETs per cycle would otherwise be
    # ~6k round-trips every 2 minutes.
    def sync(live:, configured_game_ids:, complete_game_ids:, excluded: Set.new)
      now = Time.current.iso8601
      current = entries
      stats = Stats.new(joined: 0, parted: 0, kept: 0, skipped_incomplete: 0)
      writes = [] # [:hset, login, json] | [:part, login]

      live.each do |login, game_id|
        next if excluded.include?(login)

        if (entry = current[login])
          writes << [ :hset, login, entry.merge("game_id" => game_id, "last_seen_at" => now, "misses" => 0).to_json ]
          stats.kept += 1
        else
          writes << [ :hset, login, { "game_id" => game_id, "first_seen_at" => now, "last_seen_at" => now, "misses" => 0 }.to_json ]
          writes << [ :join, login ]
          stats.joined += 1
        end
      end

      current.each do |login, entry|
        next if live.key?(login) && !excluded.include?(login) # kept above

        game_id = entry["game_id"].to_s
        if excluded.include?(login) || !configured_game_ids.include?(game_id)
          writes << [ :part, login ]
          stats.parted += 1
        elsif !complete_game_ids.include?(game_id)
          stats.skipped_incomplete += 1
        else
          misses = entry["misses"].to_i + 1
          if misses >= OFFLINE_MISS_THRESHOLD
            writes << [ :part, login ]
            stats.parted += 1
          else
            writes << [ :hset, login, entry.merge("misses" => misses).to_json ]
          end
        end
      end

      flush(writes)
      stats
    end

    def publish(action, login, conn = redis)
      conn.publish(COMMANDS_CHANNEL, { action: action, channel_login: login }.to_json)
    end

    private

    def flush(writes)
      return if writes.empty?

      redis.pipelined do |pipe|
        writes.each do |op, login, json|
          case op
          when :hset then pipe.hset(SET_KEY, login, json)
          when :join then publish("join", login, pipe)
          when :part
            pipe.hdel(SET_KEY, login)
            publish("part", login, pipe)
          end
        end
      end
    end

    def redis
      @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    end
  end
end
