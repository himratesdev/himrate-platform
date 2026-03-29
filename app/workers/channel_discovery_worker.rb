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

    streams = helix.get_streams(user_logins: [], user_ids: [])
    # get_streams without params returns top streams
    # Use top_streams GQL for better data
    streams_data = gql.top_streams(first: 100)

    new_channels = 0
    streams_data.each do |stream|
      next unless stream[:viewers_count].to_i >= MIN_VIEWERS

      channel = Channel.find_or_initialize_by(login: stream[:login])
      if channel.new_record?
        channel.twitch_id = resolve_twitch_id(stream[:login])
        channel.is_monitored = true
        channel.save!

        subscribe_eventsub(channel)
        new_channels += 1
      end
    end

    Rails.logger.info("ChannelDiscoveryWorker: scanned #{streams_data.size} streams, #{new_channels} new channels")
    schedule_next
  end

  private

  def resolve_twitch_id(login)
    users = helix.get_users(logins: [ login ])
    users&.first&.dig("id")
  end

  def subscribe_eventsub(channel)
    return unless channel.twitch_id

    Twitch::EventSubService.new.subscribe(broadcaster_id: channel.twitch_id)
  rescue StandardError => e
    Rails.logger.warn("ChannelDiscoveryWorker: EventSub subscribe failed for #{channel.login} (#{e.message})")
  end

  def schedule_next
    self.class.perform_in(DISCOVERY_INTERVAL)
  end

  def gql
    @gql ||= Twitch::GqlClient.new
  end

  def helix
    @helix ||= Twitch::HelixClient.new
  end
end
