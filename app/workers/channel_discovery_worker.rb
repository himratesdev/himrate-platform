# frozen_string_literal: true

# TASK-025 / TASK-251.13: auto-discover new channels for monitoring (hybrid set, broad side).
#
# Quality-gated discovery (TASK-251.13): instead of the global top at 50+ viewers (which swept in
# casino/restream/viewbot noise), scan the top live RU streams and only auto-monitor channels that
# clear a real-streamer bar with a tiered viewer floor by monetization status:
#   - affiliate/partner (Twitch-vetted monetization): viewer_count >= MIN_VIEWERS_MONETIZED (300)
#   - non-monetized ("regular" streamers, e.g. a pro who never enabled affiliate but streams a lot):
#     viewer_count >= MIN_VIEWERS_UNMONETIZED (500) — higher bar to offset the missing vetting
# This admits legit non-partner streamers (PO call) while keeping the floor high enough that
# casino/viewbot noise is filtered (sustaining 500 fake viewers is hard, and our ERV/TI + the
# TASK-251.2 prune catch any that slip through). Pinned curated channels (TASK-251.12) are seeded
# separately and cover must-haves that don't pass the auto-gate. Metadata is filled at creation
# via the shared Channel#assign_helix_metadata.

class ChannelDiscoveryWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  DISCOVERY_INTERVAL = 300 # seconds — used by sidekiq-cron, documented here for reference
  LANGUAGE = "ru"          # focus the target market (curated set is RU); cuts global non-RU noise
  MIN_VIEWERS_MONETIZED = 300   # affiliate/partner — Twitch monetization vetting, lower bar
  MIN_VIEWERS_UNMONETIZED = 500 # non-partner — higher bar offsets the missing vetting
  MAX_STREAMS = 100        # Helix /streams page cap; the worker re-runs every DISCOVERY_INTERVAL
  MONETIZED_TYPES = %w[affiliate partner].freeze

  def perform
    # Gate on both the master monitoring switch and the dedicated discovery flag so discovery can be
    # paused independently (kill-switch) without halting live-detection/chat (which use :stream_monitor).
    return unless Flipper.enabled?(:stream_monitor) && Flipper.enabled?(:channel_discovery)

    streams = helix.get_streams(language: LANGUAGE, first: MAX_STREAMS) || []
    # Pre-filter on the lower bar: nothing below MIN_VIEWERS_MONETIZED can qualify under either tier.
    prelim = streams.select { |s| s["viewer_count"].to_i >= MIN_VIEWERS_MONETIZED }
    stats = discover(prelim, broadcaster_users(prelim.map { |s| s["user_id"] }.compact))

    Rails.logger.info(
      "ChannelDiscoveryWorker: #{streams.size} #{LANGUAGE} streams, #{prelim.size} >=#{MIN_VIEWERS_MONETIZED}v, " \
      "#{stats[:qualified]} qualified (mon>=#{MIN_VIEWERS_MONETIZED}/other>=#{MIN_VIEWERS_UNMONETIZED}), #{stats[:created]} new channels"
    )
    # Scheduling via sidekiq-cron (config/initializers/sidekiq_cron.rb)
  end

  private

  # Apply the tiered gate to each prelim candidate and create the new monitored channels.
  # Returns { qualified:, created: } for the summary log.
  def discover(prelim, users)
    qualified = prelim.select { |stream| qualifies?(stream, users[stream["user_id"]]) }
    created = qualified.count { |stream| create_channel_safely(stream, users[stream["user_id"]]) }
    { qualified: qualified.size, created: created }
  end

  # Tiered viewer floor: monetized channels qualify at the lower bar, everyone else at the higher.
  # An unresolved user (nil — Helix didn't return it) is gated out: can't verify → don't admit.
  def qualifies?(stream, user)
    return false if user.nil?

    floor = MONETIZED_TYPES.include?(user["broadcaster_type"]) ? MIN_VIEWERS_MONETIZED : MIN_VIEWERS_UNMONETIZED
    stream["viewer_count"].to_i >= floor
  end

  # Create one channel, isolating per-stream errors so a single failure doesn't abort the run.
  def create_channel_safely(stream, user)
    process_stream(stream, user)
  rescue StandardError => e
    Rails.logger.warn("ChannelDiscoveryWorker: failed for #{stream["user_login"]} (#{e.message})")
    false
  end

  # Resolve broadcaster_type (+ metadata) for the candidate user_ids. ids come from get_streams
  # (live, valid numeric) so /users won't 400. Returns {id => helix_user}; unresolved ids are
  # absent → gated out (can't verify → don't admit).
  def broadcaster_users(ids)
    return {} if ids.empty?

    users = helix.get_users(ids: ids) || []
    users.index_by { |u| u["id"] }
  end

  # Monitor a qualifying channel: create it, or re-monitor an existing unmonitored one (e.g. a
  # channel the TASK-251.2 prune unmonitored that has since returned live and re-cleared the gate).
  # Returns true when it (re)monitored, false when already monitored / malformed. Fills metadata
  # from the already-fetched Helix user (shared Channel#assign_helix_metadata).
  def process_stream(stream, user)
    twitch_id = stream["user_id"]
    login = stream["user_login"]&.downcase
    return false unless twitch_id && login

    channel = Channel.find_or_initialize_by(twitch_id: twitch_id)
    return false if channel.is_monitored? || channel.deleted_at.present? # already monitored or soft-deleted → leave it

    was_new = channel.new_record?
    channel.login = login
    channel.is_monitored = true
    channel.assign_helix_metadata(user)
    channel.save!

    subscribe_eventsub(channel) if was_new # existing channels keep their subscription; pull-based detector covers them
    Rails.logger.info("ChannelDiscoveryWorker: #{was_new ? "new" : "re-monitored"} channel #{login} (#{twitch_id}, #{user["broadcaster_type"].presence || "none"}, #{stream["viewer_count"]}v)")
    true
  end

  def subscribe_eventsub(channel)
    Twitch::EventSubService.new.subscribe(broadcaster_id: channel.twitch_id)
  rescue StandardError => e
    Rails.logger.warn("ChannelDiscoveryWorker: EventSub subscribe failed for #{channel.login} (#{e.message})")
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
