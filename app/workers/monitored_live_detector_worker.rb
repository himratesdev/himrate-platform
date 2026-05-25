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
  MISS_KEY_PREFIX = "live_detector:offline_misses:" # + channel.id

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    live_by_twitch_id = fetch_live_streams
    return if live_by_twitch_id.nil? # every Helix batch failed — skip cycle, change nothing

    open_new_streams(live_by_twitch_id)
    close_ended_streams(live_by_twitch_id)

    Rails.logger.info("MonitoredLiveDetectorWorker: #{live_by_twitch_id.size} live among monitored")
  end

  private

  # { twitch_id => helix_stream_hash } for currently-live monitored channels.
  # Returns nil if EVERY batch failed, so the caller skips close-reconciliation
  # (no data ≠ everyone offline). A partial failure just leaves that batch's
  # channels untouched this cycle.
  def fetch_live_streams
    ids = Channel.monitored.active.pluck(:twitch_id).compact
    return {} if ids.empty?

    live = {}
    any_success = false
    ids.each_slice(HELIX_BATCH_SIZE) do |batch|
      data = helix.get_streams(user_ids: batch)
      next if data.nil?

      any_success = true
      data.each { |s| live[s["user_id"]] = s }
    end
    any_success ? live : nil
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
  def close_ended_streams(live_by_twitch_id)
    Channel.monitored.active
           .joins(:streams).where(streams: { ended_at: nil })
           .distinct.find_each do |channel|
      live_by_twitch_id.key?(channel.twitch_id) ? reset_misses(channel) : register_offline_miss(channel)
    end
  end

  def register_offline_miss(channel)
    misses = redis.incr("#{MISS_KEY_PREFIX}#{channel.id}").to_i
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
