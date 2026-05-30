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
      "channel_prune" => {
        "cron" => "17 * * * *", # hourly (offset :17 to avoid colliding with other jobs)
        "class" => "ChannelPruneWorker",
        "queue" => "monitoring",
        "description" => "TASK-251.2: unmonitor banned non-pinned channels (gated by :channel_prune, OFF until reviewed)"
      },
      # BUG-251.29: stale-stream sweep. Closes Stream rows with ended_at NULL but no CCV
      # activity in the last 30 min. Complements MonitoredLiveDetector (Helix-based) for the
      # residual stale-row case (EventSub stream.offline missed AND Helix sweep partial fail).
      # Gated by :stale_stream_sweep HOOK_FLAG (enabled per-env post-deploy review).
      "stale_stream_sweep" => {
        "cron" => "*/15 * * * *", # every 15 minutes
        "class" => "StaleStreamSweepWorker",
        "queue" => "monitoring",
        "description" => "BUG-251.29: close streams with ended_at NULL but no CCV in last 30 min (gated by :stale_stream_sweep)"
      },
      "live_bot_scoring" => {
        # TASK-251.15: */10 → */30 bridge. LiveBotScoring triggers force=true SignalCompute (skips the
        # throttle) for every live stream — at hundreds of concurrent streams that forced inflow was a
        # major driver of the :signals backlog. */30 cuts it ~3× while the ClickHouse migration (the real
        # scalable fix, TASK-251.14) is built. Revert to */10 at ClickHouse cutover.
        "cron" => "*/30 * * * *", # every 30 min (bridge; was */10 — see TASK-251.15)
        "class" => "LiveBotScoringWorker",
        "queue" => "signals",
        "description" => "TASK-251.8: periodic bot-scoring of live streams (mid-stream bot presence). Cadence */30 (TASK-251.15 bridge)"
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
      # TASK-251.58: ClickHouse chat backfill cron-driven cycle. Replaces the previous
      # `detached rake + setsid wrapper` operator pattern that died on every Kamal deploy
      # (container swap) and required manual re-spawn — 4× kills observed during TASK-251.14
      # chat backfill window 2026-05-29. The worker timeboxes a #tick loop at ~50s
      # (< 60s cron cadence + a SETNX overlap guard), Sidekiq cron registers on boot, so the
      # cycle resumes natively post-deploy. No-op when `:chat_backfill_running` OFF or T0 unset.
      # T0 (watermark) is seeded via `rake clickhouse:backfill_chat[T0_ISO]` (one-shot operator
      # action; rake writes T0 to Redis and exits — the cron worker is the sole #tick driver).
      "chat_backfill_cycle" => {
        "cron" => "* * * * *", # Every minute
        "class" => "Clickhouse::ChatBackfillCycleWorker",
        "queue" => "long_running",
        "description" => "TASK-251.58: resumable CH chat backfill cycle (gated :chat_backfill_running; T0 from Redis)"
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
      # TASK-251.W2a: snapshot monitored channels' follower count from Helix (1 call/broadcaster,
      # ≤200/run, once/day per channel via followers_synced_at). Feeds Streamer Reputation Growth
      # #12 + Follower Quality #13 (both were dead — no production writer). Frequent cron clears
      # the daily backlog in bursts then idles (stale-guard selects 0). Gated by :follower_snapshot.
      "follower_snapshot" => {
        "cron" => "*/15 * * * *", # Every 15 minutes — bounded batch covers all monitored within a day
        "class" => "FollowerSnapshotWorker",
        "queue" => "monitoring",
        "description" => "TASK-251.W2a: daily-cadence Helix follower-count snapshots (Reputation #12/#13), gated :follower_snapshot"
      },
      # TASK-251.W2b: warm the ChatterProfile cache from GQL for recently-active chatters (≤350/run,
      # ≤10 GQL batches, once/30d per chatter). BotScoringWorker reads the cache → Account Profile
      # Scoring (#11). Runs on :monitoring (off the :signals hot path). Gated by :chatter_profile_enrichment.
      "chatter_profile_enrichment" => {
        "cron" => "*/5 * * * *", # Every 5 minutes — warms the cache over time for active chatters
        "class" => "ChatterProfileRefreshWorker",
        "queue" => "monitoring",
        "description" => "TASK-251.W2b: GQL per-chatter profile cache (Account Profile Scoring #11), gated :chatter_profile_enrichment"
      },
      # TASK-251.B: classify matured raid USERNOTICEs (≥8 min old) into RaidAttribution → Raid
      # Attribution signal (#9, was blind — RaidWorker EventSub stub never wrote rows). DB-only,
      # ≤200/run; raids are sparse (~20/h) so this idles after clearing. Gated by :raid_detection.
      "raid_detection" => {
        "cron" => "*/5 * * * *", # Every 5 minutes — bounded batch clears the sparse raid backlog
        "class" => "RaidDetectionWorker",
        "queue" => "monitoring",
        "description" => "TASK-251.B: classify captured IRC raids into RaidAttribution (signal #9), gated :raid_detection"
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
      "pva_supporter_status_weekly" => {
        "cron" => "30 4 * * 1", # Mondays 04:30 UTC (weekly, off-peak)
        "class" => "PersonalAnalytics::SupporterStatusSchedulerWorker",
        "queue" => "monitoring",
        "description" => "TASK-113 M9: weekly recompute PVA supporter status (gated :pva; throttled fan-out → SupporterStatusWorker per user)"
      },
      "pva_weekly_reflection" => {
        "cron" => "45 4 * * 1", # Mondays 04:45 UTC (15 min после supporter — без overlap)
        "class" => "PersonalAnalytics::WeeklyReflectionSchedulerWorker",
        "queue" => "monitoring",
        "description" => "TASK-113 M10: weekly recompute PVA reflection narrative (gated :pva; throttled fan-out → WeeklyReflectionWorker per user, last completed week)"
      },
      "pva_patterns_weekly" => {
        "cron" => "0 5 * * 1", # Mondays 05:00 UTC (15 min после reflection)
        "class" => "PersonalAnalytics::PatternsSchedulerWorker",
        "queue" => "monitoring",
        "description" => "TASK-113 M11: weekly recompute PVA behavioral patterns (gated :pva; throttled fan-out → PatternsWorker per user, rule-based v1)"
      },
      "pva_cohort_weekly" => {
        "cron" => "15 5 * * 1", # Mondays 05:15 UTC (15 min после patterns)
        "class" => "PersonalAnalytics::CohortSchedulerWorker",
        "queue" => "monitoring",
        "description" => "TASK-113 M12: weekly recompute PVA co-watch cohort (gated :pva; throttled fan-out → CohortWorker per user with Twitch OAuth)"
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
      },
      # TASK-113 Δ-1 Wave 1 (FR-016 OQ-8, CR iter-2 M1): mark stuck enrollments partial_timeout.
      # Without this cron the sweep worker never runs → partial_timeout state unreachable,
      # retry CTA in SRS §11.6 never fires.
      "pva_enrollment_backfill_sweep" => {
        "cron" => "*/5 * * * *", # Every 5 min
        "class" => "PersonalAnalytics::Enrollment::EnrollmentBackfillSweepWorker",
        "queue" => "monitoring",
        "description" => "TASK-113 Δ-1 Wave 1 (FR-016 OQ-8): sweep stuck enrollments >10min → partial_timeout"
      }
    }

    schedule.each do |name, config_hash|
      Sidekiq::Cron::Job.create(name: name, **config_hash)
    end
  end
end
