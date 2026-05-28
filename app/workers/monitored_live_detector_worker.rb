# frozen_string_literal: true

# TASK-251.1: Autonomous live-stream detection for the monitored channel set.
#
# Gap it closes: Stream rows were only ever created by the EventSub stream.online
# handler, which is not firing for discovered channels on staging — so
# StreamMonitorWorker had no real active streams to poll and CCV/TI never accumulated.
# This worker pulls live status for ALL monitored channels via Helix Get-Streams and
# reconciles Stream rows by delegating to the existing StreamOnlineWorker /
# StreamOfflineWorker (DRY — identical create/merge/close + IRC join/part logic that
# EventSub uses). Pull-based: independent of webhook delivery, so collection starts
# autonomously the moment any monitored channel goes live.

class MonitoredLiveDetectorWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  CYCLE_INTERVAL = 60 # seconds — scheduled via sidekiq-cron, documented here for reference
  HELIX_BATCH_SIZE = 100 # Helix /streams accepts up to 100 user_id per request
  # Close a Stream only after this many consecutive cycles where the channel is absent
  # from Helix live results — debounce against transient empty responses (flapping).
  OFFLINE_MISS_THRESHOLD = 3
  # TTL on the miss counter (CR nit-1): a sub-threshold count self-expires if the stream
  # is closed by another path (e.g. EventSub) before this worker reaches the threshold,
  # so the channel drops out of close-reconciliation and the key would otherwise linger.
  MISS_KEY_TTL = OFFLINE_MISS_THRESHOLD * CYCLE_INTERVAL * 5 # seconds
  MISS_KEY_PREFIX = "live_detector:offline_misses:" # + channel.id

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    live_by_twitch_id, queried_twitch_ids, total_monitored = fetch_live_streams
    return if live_by_twitch_id.nil? # every Helix batch failed — skip cycle, change nothing

    open_new_streams(live_by_twitch_id)
    close_ended_streams(live_by_twitch_id, queried_twitch_ids)

    unqueried = total_monitored - queried_twitch_ids.size
    partial = unqueried.positive? ? " (partial: #{unqueried} channels in failed Helix sub-batch(es) — skipped this cycle)" : ""
    Rails.logger.info("MonitoredLiveDetectorWorker: #{live_by_twitch_id.size} live among #{queried_twitch_ids.size} queried#{partial}")
  end

  private

  # Returns [live_by_twitch_id, queried_twitch_ids, total_monitored]:
  #   * live_by_twitch_id — { twitch_id => helix_stream_hash } for currently-live monitored channels
  #     (only from batches that succeeded; un-queried channels never appear here).
  #   * queried_twitch_ids — Set of twitch_ids in successful batches only. Channels in FAILED
  #     sub-batches are absent → close_ended_streams skips them (un-queried ≠ offline; BUG-251.19).
  #   * total_monitored — size of the monitored set this cycle (cheap to pass through vs. a second
  #     query just for the partial-failure log marker).
  #
  # Returns [nil, nil, nil] if EVERY batch failed (no signal at all → caller skips the cycle entirely).
  # On partial failure, returns the live map + queried set so close-reconciliation runs only
  # against channels we actually have authoritative live/offline information for.
  def fetch_live_streams
    ids = Channel.monitored.active.pluck(:twitch_id).compact
    return [ {}, Set.new, 0 ] if ids.empty?

    live = {}
    queried = Set.new
    any_success = false
    ids.each_slice(HELIX_BATCH_SIZE) do |batch|
      data = helix.get_streams(user_ids: batch)
      next if data.nil?

      any_success = true
      queried.merge(batch)
      data.each { |s| live[s["user_id"]] = s }
    end
    any_success ? [ live, queried, ids.size ] : [ nil, nil, nil ]
  end

  # Live channels without an open Stream → delegate to StreamOnlineWorker (its
  # active_stream_exists? guard keeps this idempotent if a job is already queued).
  def open_new_streams(live_by_twitch_id)
    return if live_by_twitch_id.empty?

    already_live = Channel.where(twitch_id: live_by_twitch_id.keys)
                          .joins(:streams).where(streams: { ended_at: nil })
                          .pluck(:twitch_id).to_set

    live_by_twitch_id.each do |twitch_id, stream|
      next if already_live.include?(twitch_id)

      StreamOnlineWorker.perform_async(
        "broadcaster_user_id" => twitch_id,
        "broadcaster_user_login" => stream["user_login"]&.downcase,
        "started_at" => stream["started_at"]
      )
    end
  end

  # Monitored channels with an open Stream that are no longer live → debounced close.
  # BUG-251.19: scope close-reconciliation to channels in queried_twitch_ids ONLY.
  # Channels in a FAILED Helix sub-batch are absent from both the live map and the queried set
  # → must be treated as "no information this cycle", NOT as offline. Without this filter, a
  # partial Helix batch failure would falsely increment offline-miss counters for un-queried
  # channels and (after debounce) close their open streams. Self-heals on next cycle when the
  # batch succeeds (channel re-enters queried set; if still live → reset_misses, if truly
  # offline → counter resumes incrementing).
  def close_ended_streams(live_by_twitch_id, queried_twitch_ids)
    return if queried_twitch_ids.empty?

    Channel.monitored.active
           .where(twitch_id: queried_twitch_ids.to_a)
           .joins(:streams).where(streams: { ended_at: nil })
           .distinct.find_each do |channel|
      live_by_twitch_id.key?(channel.twitch_id) ? reset_misses(channel) : register_offline_miss(channel)
    end
  end

  def register_offline_miss(channel)
    key = "#{MISS_KEY_PREFIX}#{channel.id}"
    misses = redis.incr(key).to_i
    redis.expire(key, MISS_KEY_TTL) # self-clean partial counts (CR nit-1)
    return if misses < OFFLINE_MISS_THRESHOLD

    StreamOfflineWorker.perform_async(
      { "broadcaster_user_id" => channel.twitch_id, "broadcaster_user_login" => channel.login },
      "live_detector"
    )
    reset_misses(channel)
  end

  def reset_misses(channel)
    redis.del("#{MISS_KEY_PREFIX}#{channel.id}")
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
