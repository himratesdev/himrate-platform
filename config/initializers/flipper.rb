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
  redis_instance = nil # CR-iter1 #2: short-circuit pause-override probe on Redis-down
  # — without this each ALL_FLAGS loop iter would re-attempt the broken Redis +
  # raise/rescue ~18× (1s connect_timeout × 18 flags = ~18s added to cold-start boot).
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
#
# Tactical pause-override (BUG-251.21): for multi-hour disable that must survive Rails boot
# (backfill, batch migration, maintenance windows), set Redis key
#   flipper:pause_override:<flag_name> = "<reason>"
# The boot loop below respects this key by calling Flipper.disable for that flag and skipping
# the auto-enable. The pause persists across container restarts and deploys until explicit DEL.
# See `bin/rails flipper:pause:*` and docs/runbooks/flipper_tactical_pause.md.
module FlipperDefaults
  PAUSE_KEY_PREFIX = "flipper:pause_override"

  # Returns the pause-override reason string (or nil if no key / Redis error). The boot loop
  # uses the nil-or-string return to decide pause-vs-enable AND emit the reason in the audit
  # log — one Redis GET per flag instead of two probes (EXISTS + GET; CR-iter1 #1).
  #
  # Returns nil on any Redis error (degraded mode — pause check fails OPEN, flag auto-enables
  # as today). This is intentional: a flaky Redis at boot must not silently leave critical
  # production flags disabled.
  def self.pause_override_reason(flag, redis)
    return nil if redis.nil?

    redis.get("#{PAUSE_KEY_PREFIX}:#{flag}")
  rescue Redis::BaseError => e
    Rails.logger.warn("Flipper: pause-override Redis probe failed for #{flag} (#{e.message}) — falling back to auto-enable")
    nil
  end

  # Convenience predicate kept for spec/external callers — thin wrapper over the GET-based
  # `.pause_override_reason`. Boot loop calls `.pause_override_reason` directly to avoid the
  # extra method dispatch (no semantic difference, both fail open on Redis error).
  def self.pause_override_active?(flag, redis)
    !pause_override_reason(flag, redis).nil?
  end

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
    stale_stream_sweep: "BUG-251.29", # StaleStreamSweepWorker: close Stream rows with ended_at NULL
    # but no CCV activity in last 30 min. OFF by default — operator enables post-deploy after
    # confirming no false-close on legitimately live channels (e.g., dual-check against Helix).
    pva: "TASK-113", # Personal Viewer Analytics (BE-1..BE-5 + FE). OFF by default — фича шипится
    # инкрементально и ещё НЕ выпущена; enable per-env только после полного ship + verify (CR SF-3).
    # PR 1e-B (TASK-251.14): chat_messages PG table dropped — 4 chat_* flags removed
    # (chat_writes_clickhouse, chat_backfill_running, chat_reads_clickhouse_dual_read,
    # chat_reads_clickhouse). All paths now CH-only; backfill service deleted. Any future
    # re-backfill would require new source + new service implementation, не re-using these flags.
    trends_pdf_export: "TASK-078", # FR-040: PDF export из Trends Tab, добавляется отдельным PR
    billing_auto_subscription_creation: "BUG-012", # Dev/staging only: ChannelsController#track
    # auto-creates Subscription if missing. Production: flag OFF — Subscription must pre-exist
    # (payment provider webhook creates it). Prevents masking missing billing integration.
    accessory_auto_remediation: "BUG-010 PR3", # Kill switch для AutoRemediation::TriggerService
    # GitHub workflow_dispatch. Default OFF — operators enable через
    # `bin/rails accessory_ops:auto_remediation:enable` когда confident в auto path.
    cross_channel_digest: "BUG-SCW-CROSS-CHANNEL" # CrossChannelDigestRefreshWorker + ContextBuilder
    # short-circuit (read digest table instead of CH 24h scan). OFF by default — enable per-env
    # after the worker has populated the digest at least once (cron */5 min) and DV confirms
    # SCW latency drop. Toggling OFF reverts ContextBuilder to the original CH path.
  }.freeze
end

# On every boot: ensure all flags exist and are enabled.
# No manual steps. No "one-time scripts". Deploy = correct state.
#
# Two disable mechanisms — semantically distinct:
#   (a) `Flipper.disable(:flag)` (no pause key) — emergency kill switch. Holds until next deploy.
#       Container restart → initializer re-enables. Correct for "vent the steam, ship the fix."
#   (b) Pause-override key `flipper:pause_override:<flag>` — multi-hour tactical pause. Survives
#       all boots (web/sidekiq/runner/rake/deploy) until explicit DEL. Correct for backfills,
#       batch migrations, planned maintenance. See `bin/rails flipper:pause:*`.
FlipperDefaults::ALL_FLAGS.each do |flag|
  Flipper.add(flag)
  # Single Redis GET per flag — nil = no pause (auto-enable), any string = paused (disable + log).
  pause_reason = FlipperDefaults.pause_override_reason(flag, redis_instance)
  if pause_reason
    Flipper.disable(flag)
    Rails.logger.info("Flipper: pause-override active for #{flag} (reason: #{pause_reason.inspect}) — skipping auto-enable")
  else
    Flipper.enable(flag)
  end
end

# Hook flags: только add — НЕ enable. Оставляем OFF until feature ships.
# Идемпотентно: повторный boot не меняет текущее state (Flipper.add = no-op если уже
# существует, существующий enabled/disabled state preserved).
FlipperDefaults::HOOK_FLAGS.each_key do |flag|
  Flipper.add(flag)
end
