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
      },
      # BUG-010 PR2: Accessory Operations Platform schedules
      "accessory_drift_detector" => {
        "cron" => "0 * * * *", # Hourly at :00
        "class" => "AccessoryDriftDetectorWorker",
        "queue" => "accessory_ops",
        "description" => "Detect drift between deploy.yml declared image vs runtime"
      },
      "sidekiq_health_monitor" => {
        "cron" => "*/30 * * * *", # Every 30 min (ADR DEC-5)
        "class" => "SidekiqHealthMonitorWorker",
        "queue" => "monitoring",
        "description" => "Heartbeat check: alert if AccessoryDriftDetectorWorker stale >2h"
      },
      "ml_drift_forecast_trainer" => {
        "cron" => "0 3 * * 0", # Sundays 03:00 UTC (weekly, ADR DEC-13)
        "class" => "MlOps::DriftForecastTrainerService",
        "queue" => "long_running",
        "description" => "Train drift forecast model (skips if <50 events accumulated)"
      },
      "ml_drift_forecast_inference" => {
        "cron" => "0 4 * * *", # Daily at 04:00 UTC
        "class" => "MlOps::DriftForecastInferenceService",
        "queue" => "default",
        "description" => "Generate drift predictions next 30 days (skips if no model artifact)"
      },
      "cost_attribution_daily_aggregator" => {
        "cron" => "0 5 * * *", # Daily at 05:00 UTC
        "class" => "CostAttribution::DailyAggregatorWorker",
        "queue" => "accessory_ops",
        "description" => "Aggregate downtime cost (dormant pre-launch — revenue_baseline empty)"
      }
    }

    schedule.each do |name, config_hash|
      Sidekiq::Cron::Job.create(name: name, **config_hash)
    end
  end
end
