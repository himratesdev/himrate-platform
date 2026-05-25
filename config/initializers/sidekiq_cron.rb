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
      # TASK-251.1: autonomous live detection over the monitored set (Helix Get-Streams →
      # open/close Stream rows via StreamOnline/OfflineWorker). Feeds StreamMonitorWorker
      # real active streams; without it collection only ran on stale EventSub-created streams.
      # CR nit-2: shares the :monitoring 5-thread pool with stream_monitor (both minute-cadence);
      # Helix sweep ~5s for ~2.4k channels today — revisit a dedicated queue if the set grows large.
      "monitored_live_detector" => {
        "cron" => "* * * * *", # Every minute
        "class" => "MonitoredLiveDetectorWorker",
        "queue" => "monitoring",
        "description" => "Autonomous live detection: Helix Get-Streams over monitored channels → open/close Stream rows (reuses StreamOnline/OfflineWorker)"
      },
      "channel_discovery" => {
        "cron" => "*/5 * * * *", # Every 5 minutes
        "class" => "ChannelDiscoveryWorker",
        "queue" => "monitoring",
        "description" => "Quality-gated RU discovery (affiliate/partner >=300v, non-monetized >=500v)"
      },
      # TASK-251.5: bootstrap the IRC chat drainer every minute. The worker drains
      # irc:chat_messages in a loop (~50s) then exits; cron re-runs it. Without this the
      # queue was never consumed (worker self-rescheduled but was never bootstrapped) →
      # ChatMessage stayed 0 even when IRC captured chat.
      "chat_message_drain" => {
        "cron" => "* * * * *", # Every minute
        "class" => "ChatMessageWorker",
        "queue" => "chat",
        "description" => "Drain irc:chat_messages Redis queue → chat_messages (loop up to ~50s, cron-driven)"
      },
      # TASK-251.3: backfill/refresh monitored Channel metadata (display_name / avatar /
      # broadcaster_type / description) from Helix /users. Channels created by discovery/
      # EventSub carry only login + is_monitored → these were null. ≤1000 channels/run (≤10
      # Helix calls), stamped via metadata_synced_at so each refreshes at most once per 7 days.
      "channel_metadata_refresh" => {
        "cron" => "*/10 * * * *", # Every 10 minutes
        "class" => "ChannelMetadataRefreshWorker",
        "queue" => "monitoring",
        "description" => "Backfill/refresh monitored Channel metadata (display_name/avatar/...) from Helix /users"
      },
      # TASK-086 FR-010 (ADR-086 §4.8): daily retention cleanup. 03:15 UTC — staggered
      # away from bot_list_refresh (03:00) to avoid DB contention (CleanupWorker is heavy).
      "cleanup_worker_daily" => {
        "cron" => "15 3 * * *", # Daily at 03:15 UTC
        "class" => "CleanupWorker",
        "queue" => "monitoring",
        "description" => "Daily retention cleanup: TIH intermediate + signals + sessions + ccv/chatters/chat snapshots + audit"
      },
      # TASK-A1 FR-012(a): nightly safety-net re-aggregation of yesterday's TDA.
      # Dispatcher (one query + Redis enqueue) is light; heavy AggregationWorker
      # fan-out lands on :signals, paced by queue → no DB-contention at 03:00.
      "trends_aggregation_nightly" => {
        "cron" => "0 3 * * *", # Daily at 03:00 UTC (SRS FR-012a)
        "class" => "Trends::NightlyAggregationWorker",
        "queue" => "monitoring",
        "description" => "Nightly safety-net: re-aggregate yesterday's trends_daily_aggregates for channels that streamed (idempotent fan-out → AggregationWorker)"
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
        "class" => "MlOps::DriftForecastTrainerWorker",
        "queue" => "long_running",
        "description" => "Train drift forecast model (skips if <50 events accumulated)"
      },
      "ml_drift_forecast_inference" => {
        "cron" => "0 4 * * *", # Daily at 04:00 UTC
        "class" => "MlOps::DriftForecastInferenceWorker",
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
