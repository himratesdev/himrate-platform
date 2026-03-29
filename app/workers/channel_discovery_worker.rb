# frozen_string_literal: true

# TASK-025: Auto-indexing — discover new channels for monitoring.
# Periodically scans Helix top streams (50+ viewers), creates Channel records,
# subscribes to EventSub for new channels.

class ChannelDiscoveryWorker
  include Sidekiq::Job
  sidekiq_options queue: :monitoring, retry: 1

  DISCOVERY_INTERVAL = 300 # 5 minutes
  MIN_VIEWERS = 50

  def perform
    return unless Flipper.enabled?(:stream_monitor)

    streams_data = helix.get_streams(user_logins: [], user_ids: []) || []

    new_channels = 0
    streams_data.each do |stream|
      next unless stream["viewer_count"].to_i >= MIN_VIEWERS

      process_stream(stream)
      new_channels += 1
    rescue StandardError => e
      Rails.logger.warn("ChannelDiscoveryWorker: failed for #{stream["user_login"]} (#{e.message})")
    end

    Rails.logger.info("ChannelDiscoveryWorker: scanned #{streams_data.size} streams, #{new_channels} processed")
    schedule_next
  end

  private

  def process_stream(stream)
    twitch_id = stream["user_id"]
    login = stream["user_login"]&.downcase
    return unless twitch_id && login

    channel = Channel.find_or_initialize_by(twitch_id: twitch_id)
    if channel.new_record?
      channel.login = login
      channel.is_monitored = true
      channel.save!

      subscribe_eventsub(channel)
      Rails.logger.info("ChannelDiscoveryWorker: new channel #{login} (#{twitch_id})")
    end
  end

  def subscribe_eventsub(channel)
    Twitch::EventSubService.new.subscribe(broadcaster_id: channel.twitch_id)
  rescue StandardError => e
    Rails.logger.warn("ChannelDiscoveryWorker: EventSub subscribe failed for #{channel.login} (#{e.message})")
  end

  def schedule_next
    self.class.perform_in(DISCOVERY_INTERVAL)
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
