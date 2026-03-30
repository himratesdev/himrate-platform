# frozen_string_literal: true

# TASK-026: Sidekiq Cron schedule — safety net for periodic workers.
# Self-scheduling chains (perform_in) can break if both retries fail.
# Cron ensures workers restart even after chain breakage.

return unless defined?(Sidekiq::Cron)

Sidekiq.configure_server do |config|
  config.on(:startup) do
    schedule = {
      "bot_list_refresh" => {
        "cron" => "0 3 * * *", # Daily at 03:00 UTC
        "class" => "BotListRefreshWorker",
        "queue" => "monitoring",
        "description" => "Daily refresh of known bot lists from 4 external sources"
      },
      "stream_monitor" => {
        "cron" => "* * * * *", # Every minute (safety net for 60s self-scheduling)
        "class" => "StreamMonitorWorker",
        "queue" => "monitoring",
        "description" => "Periodic CCV/chatters polling (Tier 1 + Tier 2)"
      },
      "channel_discovery" => {
        "cron" => "*/5 * * * *", # Every 5 minutes
        "class" => "ChannelDiscoveryWorker",
        "queue" => "monitoring",
        "description" => "Auto-indexing top streams (50+ viewers)"
      }
    }

    schedule.each do |name, config_hash|
      Sidekiq::Cron::Job.create(name: name, **config_hash)
    end
  end
end
