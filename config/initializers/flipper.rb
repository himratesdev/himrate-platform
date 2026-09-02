# frozen_string_literal: true

require "flipper"
require "flipper/adapters/redis"
require "flipper/adapters/active_record"
require "flipper/adapters/memoizable"

# Fail fast: FLIPPER_UI_PASSWORD required in production.
# Skipped during the Docker asset precompile (SECRET_KEY_BASE_DUMMY set, runtime
# secrets absent) — the guard runs on the real runtime boot instead.
if Rails.env.production? && ENV["SECRET_KEY_BASE_DUMMY"].blank? && ENV["FLIPPER_UI_PASSWORD"].blank?
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
  # T1-060 FR-3: read the accumulating flag instead of the legacy role scalar (dropped in phase-2).
  actor.respond_to?(:is_streamer) && actor.is_streamer
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

  # NB: plain symbol array, NOT %i[] — percent-literals have no comment syntax (`#` inside
  # %i[] is a literal token, not a comment). A doc comment placed inside the former %i[]
  # got whitespace-split into ~40 symbol "flags" (:the, :boot, :"2026-07-29.", :"#", …) that
  # the boot loop below registered AND enabled on every Rails boot (incident 2026-08-05).
  # Name shape is pinned by spec/flipper/flipper_flag_registry_spec.rb.
  ALL_FLAGS = [
    :pundit_authorization,
    :bot_raid_chain,
    :compare_unlimited,
    :audience_overlap,
    :ad_calculator,
    :social_presence,
    :panel_tracking,
    :tracking_requests,
    :irc_monitor,
    :stream_monitor,
    :known_bots,
    :channel_discovery,
    :bot_scoring,
    :signal_compute,
    :accessory_drift_detection,
    :stream_summary_endpoint,
    :cleanup_worker,
    :trends_tab,
    :trends_aggregation_nightly,
    :pva,
    :ti_v2_cowindowed_shadow,
    :ti_v2_ie_shadow,
    # SA-2 social-footprint index (channel_social_links refresh). Was manually Flipper.enable'd →
    # Redis-only → reverted OFF on a redeploy, stalling the backfill at ~1026/5232 (the recurring
    # PVA «flag not deploy-proof» pattern). ALL_FLAGS makes the bounded (≤100/run) cron auto-enable
    # every boot so the pool keeps indexing. Promoted 2026-07-29.
    :social_footprint_index,
    # T1-074 PR3b cutover engine selector (48 read sites). Was NEVER registered here — flipped
    # manually via flipper-toggle.yml → Redis-only state. Every fresh boot after a Redis/DB loss
    # silently fell back to the v1 engine (4-band ERV, ti_score writers) until someone re-flipped:
    # exactly what happened on the home-server first boot 2026-08-26 21:50 → 2026-08-27 (≈28.6k
    # v1 TIH rows on a "v2-era" DB). PO 2026-09-01: v2 is the authoritative engine everywhere →
    # deploy-proof in ALL_FLAGS. Rollback path stays: pause-override key or emergency disable.
    :ti_v2_engine
  ].freeze

  # Verdict-flip flags that must be DEPLOY-PROOF on staging (survive a kamal-setup Redis flush) but stay
  # OFF on PRODUCTION until the PO-gated production rollout — enabling the windowed verdict on prod against
  # its still-cumulative ρ* cells would mismatch conventions fleet-wide. Auto-enabled ONLY on staging +
  # development (the boot loop skips production AND test — test specs assume the cumulative/dormant
  # verdict, so the flag must not flip in RAILS_ENV=test). Prod rollout = seed prod windowed cells + move
  # the flag to ALL_FLAGS (or drop the env guard). Battle-mode windowing flip 2026-07-25.
  # 2026-09-01 PO decision («прод = staging»): the single Kamal destination `staging` on the
  # home server IS the public production (himrate.com / app. / api.) until a dedicated
  # production destination exists. These flags are therefore the de-facto production operating
  # set. When a real production destination appears, that cutover is an explicit task: promote
  # to ALL_FLAGS (or drop the env guard) + seed prod windowed ρ* cells + rotate PAT — see
  # docs/runbooks/production_cutover.md.
  STAGING_ALL_FLAGS = %i[
    ti_v2_cowindowed_rho
    follower_snapshot
    chatter_profile_enrichment
    raid_detection
    stale_stream_sweep
    cross_channel_digest
    big_channel_chatter_sweep
    cross_channel_edges
    temporal_cross_channel
    saas_lk_live
    billing_auto_subscription_creation
  ].freeze
  # ^ 2026-08-28 HOSTKEY-loss incident: these ten lived in HOOK_FLAGS and were manually
  # Flipper.enable'd on the old staging box — Redis-only state that died with the server.
  # Fresh DB booted with them silently OFF: ChatterProfileRefreshWorker no-op'd →
  # chatter_profiles=0 → q_score=0 → EIHC=0 → engine mass-AMBERed the honest fleet
  # (CHATTER_QUALITY_LOW), cross-channel mc-signatures (the botnet moat) had no data, ЛК gate
  # closed. Same failure class as the PVA P0 (see HOOK_FLAGS doc below). Promoted here so a
  # staging boot restores the July-verified operating set with no manual step; prod stays OFF
  # (per-env rollout unchanged). Original traceability: follower_snapshot TASK-251.W2a ·
  # chatter_profile_enrichment TASK-251.W2b · raid_detection TASK-251.B · stale_stream_sweep
  # BUG-251.29 · cross_channel_digest BUG-SCW-CROSS-CHANNEL · big_channel_chatter_sweep
  # BUG-251.31-G3-PR-A2 · cross_channel_edges/temporal_cross_channel T1-057 · saas_lk_live
  # LK-BACKEND · billing_auto_subscription_creation BUG-012 (staging/dev-only by design —
  # production must keep it OFF, which the env-guarded boot loop guarantees).

  # Hooks for upcoming features / transitional kill-switches: flag зарегистрирован,
  # но НЕ auto-enabled. Production state управляется отдельно (миграция / admin UI /
  # rake task). Каждая запись = namespaced :flag => "TASK-XXX reference" для traceability.
  HOOK_FLAGS = {
    channel_prune: "TASK-251.2", # Destructive ChannelPruneWorker (unmonitor banned non-pinned).
    # OFF by default — enabled per-env only after a dry-run review confirms the prune set.
    # pva (TASK-113): PVA is SHIPPED → moved to ALL_FLAGS (auto-enabled every boot) 2026-07-22.
    # Root cause of the P0: it was add-only here, so a manual Flipper.enable lived only in Redis and
    # a Redis clear / redeploy reverted it to OFF → all enrollment/aggregation workers no-op'd
    # (return unless Flipper.enabled?(:pva)) → cold-start sources stuck "в очереди" forever, retry
    # useless. ALL_FLAGS makes it deploy-proof (the recurring "flags not auto-created" pattern).
    # 2026-08-28: the same failure class hit ten more manually-enabled flags when the HOSTKEY box
    # (and its Redis) was terminated — they are now in STAGING_ALL_FLAGS above; see that comment.
    # PR 1e-B (TASK-251.14): chat_messages PG table dropped — 4 chat_* flags removed
    # (chat_writes_clickhouse, chat_backfill_running, chat_reads_clickhouse_dual_read,
    # chat_reads_clickhouse). All paths now CH-only; backfill service deleted. Any future
    # re-backfill would require new source + new service implementation, не re-using these flags.
    trends_pdf_export: "TASK-078", # FR-040: PDF export из Trends Tab, добавляется отдельным PR
    accessory_auto_remediation: "BUG-010 PR3", # Kill switch для AutoRemediation::TriggerService
    ti_v2_shadow: "T1-074 PR2b", # v1-primary shadow compute (log-only). Meaningful only while
    # ti_v2_engine is OFF; with the cutover flag in ALL_FLAGS this stays a dormant kill-switch-era
    # hook. Registered so the flag exists deploy-proof instead of living as Redis-only state.
    po_debug_dashboard: "TASK-PO-DEBUG-DASHBOARD" # /dashboard/po-debug gate. Was registered only by
    # migration 20260606030000 (Flipper.disable in `up`) → absent on any DB созданной после неё →
    # controller 503'd on a fresh box. Registered add-only here; PO enables manually when needed.
    # GitHub workflow_dispatch. Default OFF — operators enable через
    # `bin/rails accessory_ops:auto_remediation:enable` когда confident в auto path.
    # NB: ti_v2_ie_shadow (i_event magnitude harvester, PR-i4) was PROMOTED to ALL_FLAGS 2026-07-23 —
    # the honest-corpus for the C_self floor calibration must accrue continuously across redeploys
    # (HOOK_FLAGS is Redis-only → reverts OFF on redeploy, PVA lesson). cost-DSV verified safe
    # (2 bounded indexed plucks, p50 5ms/tick, PG ~2.5% of the 30s cycle spread by shard). It rides the
    # ti_v2_cowindowed_shadow duty; the VERDICT stays dormant (i_event_enabled=0.0). Move back to HOOK +
    # disable after the floors are calibrated + the flip lands.
    # NB: ti_v2_cowindowed_shadow (P1 windowed shadow-accrual) was PROMOTED to ALL_FLAGS 2026-07-22 —
    # the windowed-ρ_obs corpus for the P2 re-seed must accrue continuously across redeploys (HOOK_FLAGS
    # is Redis-only → reverts OFF on redeploy, PVA lesson). The added load is DSV-verified safe (win_pg
    # ~1ms; PG +0.4% at duty 1/4). The VERDICT stays cumulative (separate flag ti_v2_cowindowed_rho, OFF).
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
# Skip the boot-time flag sync during the Docker asset precompile: the build has
# no Redis/DB accessories, and Flipper.add/enable would hit the database. The
# sync is idempotent and runs on every real runtime boot (accessories present).
unless ENV["SECRET_KEY_BASE_DUMMY"].present?
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

  # STAGING-only deploy-proof flags: auto-enable on staging + development only (prod rollout is PO-gated
  # and must seed prod windowed cells first; test stays cumulative so specs are unaffected). Same add +
  # pause-override + enable semantics as ALL_FLAGS.
  if Rails.env.staging? || Rails.env.development?
    FlipperDefaults::STAGING_ALL_FLAGS.each do |flag|
      Flipper.add(flag)
      pause_reason = FlipperDefaults.pause_override_reason(flag, redis_instance)
      if pause_reason
        Flipper.disable(flag)
        Rails.logger.info("Flipper: pause-override active for #{flag} (reason: #{pause_reason.inspect}) — skipping auto-enable")
      else
        Flipper.enable(flag)
      end
    end
  end

  # Hook flags: только add — НЕ enable. Оставляем OFF until feature ships.
  # Идемпотентно: повторный boot не меняет текущее state (Flipper.add = no-op если уже
  # существует, существующий enabled/disabled state preserved).
  FlipperDefaults::HOOK_FLAGS.each_key do |flag|
    Flipper.add(flag)
  end
end
