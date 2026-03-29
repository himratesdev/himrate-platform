# frozen_string_literal: true

# TASK-023: EventSub channel.update handler.
# TASK-025: Update active Stream title/game_name on category change.
# Provides context for CCV anomaly attribution (category change = organic, not bots).

class ChannelUpdateWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals

  def perform(event_data)
    broadcaster_id = event_data["broadcaster_user_id"]
    title = event_data["title"]
    category_name = event_data["category_name"]

    channel = Channel.find_by(twitch_id: broadcaster_id)
    unless channel
      Rails.logger.info("ChannelUpdateWorker: channel not found for #{broadcaster_id}")
      return
    end

    stream = channel.streams.where(ended_at: nil).order(started_at: :desc).first
    unless stream
      Rails.logger.info("ChannelUpdateWorker: no active stream for #{channel.login}, skipping")
      return
    end

    old_game = stream.game_name
    stream.update!(title: title, game_name: category_name)

    if old_game != category_name
      Rails.logger.info("ChannelUpdateWorker: #{channel.login} changed category: #{old_game} → #{category_name}")
    end
  end
end
