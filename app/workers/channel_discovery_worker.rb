# frozen_string_literal: true

# TASK-025 / TASK-251.13: auto-discover new channels for monitoring (hybrid set, broad side).
#
# Quality-gated discovery (TASK-251.13): instead of the global top at 50+ viewers (which swept in
# casino/restream/viewbot noise), scan the top live RU streams and only auto-monitor channels that
# clear a real-streamer bar — viewer_count >= MIN_VIEWERS AND broadcaster_type in {affiliate,
# partner} (Twitch's own monetization vetting: affiliate needs 50 followers + 3 avg viewers + 500
# streamed min + 7 unique days, which throwaway viewbot/casino-spam accounts don't have, while real
# growing newcomers reach it quickly). Pinned curated channels (TASK-251.12) are seeded separately;
# this finds the long tail of legit new RU streamers. Metadata is filled at creation via the shared
# Channel#assign_helix_metadata.

class ChannelDiscoveryWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  DISCOVERY_INTERVAL = 300 # seconds — used by sidekiq-cron, documented here for reference
  LANGUAGE = "ru"          # focus the target market (curated set is RU); cuts global non-RU noise
  MIN_VIEWERS = 300        # real, established/growing streamers worth tracking; cuts the long tail
  MAX_STREAMS = 100        # Helix /streams page cap; the worker re-runs every DISCOVERY_INTERVAL
  MONETIZED_TYPES = %w[affiliate partner].freeze # Twitch monetization gate vs viewbot/casino spam

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    streams = helix.get_streams(language: LANGUAGE, first: MAX_STREAMS) || []
    candidates = streams.select { |s| s["viewer_count"].to_i >= MIN_VIEWERS }
    monetized = monetized_users(candidates.map { |s| s["user_id"] }.compact)

    new_count = 0
    candidates.each do |stream|
      user = monetized[stream["user_id"]]
      next if user.nil? # not affiliate/partner → fails the quality gate, skip

      new_count += 1 if process_stream(stream, user)
    rescue StandardError => e
      Rails.logger.warn("ChannelDiscoveryWorker: failed for #{stream["user_login"]} (#{e.message})")
    end

    Rails.logger.info(
      "ChannelDiscoveryWorker: #{streams.size} #{LANGUAGE} streams, #{candidates.size} >=#{MIN_VIEWERS}v, " \
      "#{monetized.size} monetized, #{new_count} new channels"
    )
    # Scheduling via sidekiq-cron (config/initializers/sidekiq_cron.rb)
  end

  private

  # Resolve broadcaster_type for the candidate user_ids and keep only monetized (affiliate/partner).
  # ids come from get_streams (live, valid numeric) so /users won't 400. Returns {id => helix_user}.
  def monetized_users(ids)
    return {} if ids.empty?

    users = helix.get_users(ids: ids) || []
    users.select { |u| MONETIZED_TYPES.include?(u["broadcaster_type"]) }.index_by { |u| u["id"] }
  end

  # Returns true if a new channel was created. Fills metadata at creation from the already-fetched
  # Helix user (shared mapping with the metadata worker / seeder — Channel#assign_helix_metadata).
  def process_stream(stream, user)
    twitch_id = stream["user_id"]
    login = stream["user_login"]&.downcase
    return false unless twitch_id && login

    channel = Channel.find_or_initialize_by(twitch_id: twitch_id)
    return false unless channel.new_record?

    channel.login = login
    channel.is_monitored = true
    channel.assign_helix_metadata(user)
    channel.save!

    subscribe_eventsub(channel)
    Rails.logger.info("ChannelDiscoveryWorker: new channel #{login} (#{twitch_id}, #{user["broadcaster_type"]})")
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
