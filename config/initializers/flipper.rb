# frozen_string_literal: true

require "flipper"
require "flipper/adapters/redis"
require "flipper/adapters/active_record"
require "flipper/adapters/memoizable"

# Fail fast: FLIPPER_UI_PASSWORD required in production
if Rails.env.production? && ENV["FLIPPER_UI_PASSWORD"].blank?
  raise "FLIPPER_UI_PASSWORD must be set in production"
end

# Primary: Redis (fast). Fallback: ActiveRecord (durable).
# Memoize: per-request cache on top.
redis_url = ENV.fetch("REDIS_URL", "redis://localhost:6379/1")

begin
  redis_instance = Redis.new(url: redis_url)
  redis_instance.ping
  redis_adapter = Flipper::Adapters::Redis.new(redis_instance)
rescue Redis::CannotConnectError, Redis::TimeoutError => e
  Rails.logger.error("Flipper: Redis unavailable (#{e.message}), using ActiveRecord only")
  redis_adapter = nil
end

ar_adapter = Flipper::Adapters::ActiveRecord.new

primary_adapter = redis_adapter || ar_adapter
memoized = Flipper::Adapters::Memoizable.new(primary_adapter)

Flipper.configure do |config|
  config.adapter { memoized }
end

# Instrumenter for audit logging
ActiveSupport::Notifications.subscribe(/flipper/) do |name, _start, _finish, _id, payload|
  next unless name.include?("feature_operation")

  Rails.logger.info(
    "Flipper audit: operation=#{payload[:operation]} " \
    "feature=#{payload[:feature_name]} " \
    "gate=#{payload[:gate_name]} " \
    "thing=#{payload[:thing]}"
  )
end

# Groups (per BRD BR-005)
Flipper.register(:premium_users) do |actor|
  actor.respond_to?(:tier) && actor.tier == "premium"
end

Flipper.register(:business_users) do |actor|
  actor.respond_to?(:tier) && actor.tier == "business"
end

Flipper.register(:streamers) do |actor|
  actor.respond_to?(:role) && actor.role == "streamer"
end

# Single source of truth for all feature flags.
# Paywall enforcement = Pundit policies. Flipper = kill switches only.
# Default state = enabled. Disable only in emergency.
module FlipperDefaults
  ALL_FLAGS = %i[
    pundit_authorization
    bot_raid_chain
    compare_unlimited
    audience_overlap
    ad_calculator
    social_presence
    panel_tracking
    tracking_requests
    irc_monitor
    stream_monitor
    known_bots
    channel_discovery
    bot_scoring
    signal_compute
    accessory_drift_detection
    stream_summary_endpoint
    cleanup_worker
    trends_tab
    trends_aggregation_nightly
  ].freeze

  # Hooks for upcoming features / transitional kill-switches: flag зарегистрирован,
  # но НЕ auto-enabled. Production state управляется отдельно (миграция / admin UI /
  # rake task). Каждая запись = namespaced :flag => "TASK-XXX reference" для traceability.
  HOOK_FLAGS = {
    channel_prune: "TASK-251.2", # Destructive ChannelPruneWorker (unmonitor banned non-pinned).
    # OFF by default — enabled per-env only after a dry-run review confirms the prune set.
    follower_snapshot: "TASK-251.W2a", # FollowerSnapshotWorker: daily Helix follower-count
    # snapshots → Streamer Reputation Growth #12 / Follower Quality #13. OFF by default —
    # additive data collection, enabled per-env post-deploy (same pattern as other monitoring workers).
    chatter_profile_enrichment: "TASK-251.W2b", # ChatterProfileRefreshWorker: GQL per-chatter
    # profile cache → Account Profile Scoring (#11). OFF by default — additive, enabled per-env.
    raid_detection: "TASK-251.B", # RaidDetectionWorker: classify captured IRC raid USERNOTICEs into
    # RaidAttribution → Raid Attribution signal (#9). OFF by default — additive, enabled per-env.
    pva: "TASK-113", # Personal Viewer Analytics (BE-1..BE-5 + FE). OFF by default — фича шипится
    # инкрементально и ещё НЕ выпущена; enable per-env только после полного ship + verify (CR SF-3).
    chat_writes_clickhouse: "TASK-251.14b", # Dual-write ChatMessageWorker → ClickHouse (best-effort;
    # Postgres stays source of truth). OFF by default — enable per-env only after ingest-parity is
    # validated. Read migration (ContextBuilder → CH) is a separate flag :chat_reads_clickhouse (1d).
    chat_backfill_running: "TASK-251.14c", # Kill-switch for `rake clickhouse:backfill_chat`. OFF by
    # default — operator flips ON to start the one-shot backfill, OFF to pause cleanly (the loop
    # exits at the next batch boundary with the Redis cursor preserved → re-running resumes).
    chat_reads_clickhouse_dual_read: "TASK-251.14d", # ContextBuilder validation flag: ON → run BOTH
    # PG and CH chat queries, log divergence, return PG result (safe). Phase 1 of the read-migration
    # — monitor divergence; flip :chat_reads_clickhouse once it's 0 over a stable window.
    chat_reads_clickhouse: "TASK-251.14d", # ContextBuilder cutover flag: ON → CH-only chat reads.
    # Combat: signals offload to the minute MV rollups, the :signals backlog drains, TI goes live.
    # Flip ONLY after dual_read shows clean 0-divergence (and the chat_messages backfill is done).
    trends_pdf_export: "TASK-078", # FR-040: PDF export из Trends Tab, добавляется отдельным PR
    billing_auto_subscription_creation: "BUG-012", # Dev/staging only: ChannelsController#track
    # auto-creates Subscription if missing. Production: flag OFF — Subscription must pre-exist
    # (payment provider webhook creates it). Prevents masking missing billing integration.
    accessory_auto_remediation: "BUG-010 PR3" # Kill switch для AutoRemediation::TriggerService
    # GitHub workflow_dispatch. Default OFF — operators enable через
    # `bin/rails accessory_ops:auto_remediation:enable` когда confident в auto path.
  }.freeze
end

# On every boot: ensure all flags exist and are enabled.
# No manual steps. No "one-time scripts". Deploy = correct state.
# Emergency disable: Flipper.disable(:flag) holds until next deploy.
# When the fix is deployed → container restarts → flag back to enabled. Correct behavior.
FlipperDefaults::ALL_FLAGS.each do |flag|
  Flipper.add(flag)
  Flipper.enable(flag)
end

# Hook flags: только add — НЕ enable. Оставляем OFF until feature ships.
# Идемпотентно: повторный boot не меняет текущее state (Flipper.add = no-op если уже
# существует, существующий enabled/disabled state preserved).
FlipperDefaults::HOOK_FLAGS.each_key do |flag|
  Flipper.add(flag)
end
