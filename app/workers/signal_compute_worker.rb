# frozen_string_literal: true

# TASK-030: Signal Compute Worker.
# Orchestrates full pipeline: context → signals → interaction → anomaly → TI/ERV → persist → publish.
# Triggered by StreamMonitorWorker (live, per stream) and BotScoringWorker (final, post-stream).
# Throttle from DB (signal_configurations). Flipper[:signal_compute] gate.
#
# Telemetry (Phase 2 G, 2026-06-03): each pipeline stage emits a tagged
# ActiveSupport::Notifications event ("scw.<stage>") + Sentry breadcrumb. When a
# stage raises, Sentry.capture_exception is called with stage + stream_id tagged
# in the scope so failures land in Sentry pre-grouped by stage. This addresses
# the «probe ONE function ≠ end-to-end verified» pattern documented in
# `memory/feedback_telemetry_first_diagnostic.md` — when SCW fails, we now know
# WHICH stage from the tagged event without re-deriving from log lines.

class SignalComputeWorker
  include Sidekiq::Job
  # Phase 5 follow-up (2026-05-31): dedicated :signal_compute queue so new TI recompute
  # jobs bypass the historical :signals 1M+ backlog (same fix pattern as PR #229
  # :bot_scoring). String value (not Symbol) per CR-229 iter-2 — Sidekiq stores option
  # values verbatim, and queue introspection in specs/cron-enqueue paths assumes String.
  sidekiq_options queue: "signal_compute", retry: 3

  THROTTLE_KEY_PREFIX = "signal_compute:throttle:"
  PUBLISH_CHANNEL_PREFIX = "ti:updates:"
  DEFAULT_THROTTLE_SECONDS = 30

  # Ordered list of pipeline stage names. Each is the AS::N event suffix
  # ("scw.<stage>") + Sentry breadcrumb category. Kept here as a single source
  # so the spec can assert exhaustive coverage.
  PIPELINE_STAGES = %w[
    context_build
    signals_compute
    interaction_matrix
    anomaly_alerter
    engine_compute
    extra_detectors
    cache_invalidate
    publish_update
    signal_health_track
  ].freeze

  # FR-009: Dead letter — anomaly record on exhausted retries
  sidekiq_retries_exhausted do |job, ex|
    stream = Stream.find_by(id: job["args"].first)
    if stream
      Anomaly.create!(
        stream: stream,
        timestamp: Time.current,
        anomaly_type: "compute_failure",
        details: { error: ex.class.name, message: ex.message, job_id: job["jid"] }
      )
      Rails.logger.error("SignalComputeWorker: exhausted retries for stream #{stream.id} — #{ex.message}")
    end
  rescue StandardError => e
    Rails.logger.error("SignalComputeWorker: dead letter failed — #{e.message}")
  end

  # perform(stream_id, force: false)
  # force=true skips throttle (used for final post-stream compute)
  def perform(stream_id, force = false)
    return unless Flipper.enabled?(:signal_compute)

    stream = Stream.find_by(id: stream_id)
    unless stream
      Rails.logger.warn("SignalComputeWorker: stream #{stream_id} not found")
      return
    end

    # FR-002/008: Throttle (skip if force=true for final compute)
    unless force
      return if throttled?(stream_id)
    end

    started_at = Time.current

    # FR-003: Build context
    context = instrument_stage("context_build", stream_id) do
      TrustIndex::ContextBuilder.build(stream)
    end

    # FR-004: Full pipeline
    signal_results = instrument_stage("signals_compute", stream_id) do
      TrustIndex::Signals::Registry.compute_all(context)
    end

    interaction_output = instrument_stage("interaction_matrix", stream_id) do
      TrustIndex::Signals::InteractionMatrix.apply(signal_results)
    end

    # TASK-039 FR-019: enqueue attribution pipeline для каждой созданной anomaly.
    # AnomalyAlerter returns Array anomaly IDs (newly created, после dedup).
    anomaly_ids = instrument_stage("anomaly_alerter", stream_id) do
      TrustIndex::Signals::AnomalyAlerter.check(stream, interaction_output[:results])
    end
    anomaly_ids.each { |id| Trends::AnomalyAttributionWorker.perform_async(id) }

    result = instrument_stage("engine_compute", stream_id) do
      compute_engine(stream, context, interaction_output[:results])
    end

    # TASK-085 FR-014/015 (ADR-085 D-6 + D-8b): NEW detectors extend AnomalyAlerter pattern.
    # Run AFTER engine_compute (v1: writes TIH+ErvEstimate; v2 cutover: V2::Persistence writes TIH v2) но ДО invalidate_api_cache
    # (D-8b race window prevention — fresh anomalies visible immediately on next poll).
    extra_anomaly_ids = instrument_stage("extra_detectors", stream_id) do
      TrustIndex::Signals::TiDropDetector.check(stream) +
        TrustIndex::Signals::ErvDivergenceDetector.check(stream)
    end
    extra_anomaly_ids.each { |id| Trends::AnomalyAttributionWorker.perform_async(id) }

    # TASK-032 CR #16: Explicit cache invalidation after TI compute
    instrument_stage("cache_invalidate", stream_id) do
      invalidate_api_cache(stream.channel_id)
    end

    # FR-005: Redis publish
    instrument_stage("publish_update", stream_id) do
      publish_update(stream, result)
    end

    # FR-010: Signal health tracking
    instrument_stage("signal_health_track", stream_id) do
      track_signal_health(signal_results)
    end

    duration_ms = ((Time.current - started_at) * 1000).to_i
    Rails.logger.info(
      "SignalComputeWorker: stream #{stream_id} — engine=#{result&.engine_version} " \
      "duration=#{duration_ms}ms force=#{force}"
    )
  end

  private

  # T1-074 PR2b/PR3b (ADR DEC-2/DEC-7) — engine selection.
  # ti_v2_engine ON (PR3b CUTOVER): v2 is AUTHORITATIVE — v1 is not computed, not persisted, not
  #   published (the discredited v1 verdict layer dies here; signals/anomaly stages above still run —
  #   they are real measurements both engines share). v2 persists via V2::Persistence and publishes
  #   through the engine-agnostic to_headline_payload. NO rescue: a v2 failure fails the stage
  #   (Sidekiq retry + dead-letter), unlike shadow — v2 is the product now.
  # ti_v2_engine OFF: v1 authoritative exactly as before; ti_v2_shadow optionally logs the v1↔v2
  #   diff (compute+log only, no persist — zero TIH pollution).
  def compute_engine(stream, context, signal_results)
    return cutover_compute_v2(stream, context) if ti_v2_engine?

    v1 = TrustIndex::Engine.new.compute(
      signal_results: signal_results, stream: stream,
      ccv: context[:latest_ccv] || 0, category: context[:category] || "default"
    )
    shadow_compute_v2(stream, context, v1) if ti_v2_shadow?
    v1
  end

  def ti_v2_shadow?
    Flipper.enabled?(:ti_v2_shadow)
  rescue StandardError
    false
  end

  def ti_v2_engine?
    Flipper.enabled?(:ti_v2_engine)
  rescue StandardError
    false
  end

  # PR3b cutover path: build v2 context (reuses the v1-built context Hash — no second CH scan),
  # compute, persist (TIH engine_version='v2' + NamedBotEvidence on C_hard), and keep the
  # calibration-observables stream alive (mining continuity: ti-v2-shadow-mine parses "SCW shadow"
  # lines; v1_* keys are null post-cutover — the miner only reads the v2_* observables).
  def cutover_compute_v2(stream, context)
    v2_context = TrustIndex::ContextBuilder.build_v2(stream, context)
    v2 = TrustIndex::V2::Engine.compute(context: v2_context, k: Calibration::Registry.load)
    TrustIndex::V2::Persistence.call(result: v2, channel: stream.channel, stream: stream,
                                     calculated_at: Time.current, ccv: v2_context.v)
    log_shadow(stream, nil, v2, v2_context)
    accrue_windowed_shadow(stream, v2_context) if windowed_shadow_due?(stream) # P1: dormant own-flag windowed accrual
    v2
  end

  # P1 (TI v2.1 BUG-A flip-path): accrue WINDOWED ρ_obs samples for the P2 re-seed WITHOUT touching the
  # verdict (which stays cumulative until the Phase C flip). Reuses the already-built cumulative context
  # and only swaps in the trailing-60min L2 inputs via Data#with → the marginal cost is exactly the windowed
  # fetch measured by ti-v2-cowindowed-cost-dsv (win_ch ~10ms CH + win_pg ~1ms PG), NOT a second full build.
  # Emits a shadow line with v2_rho_conv="windowed" so ti-v2-shadow-mine (convention=windowed) mines it.
  # A defect is swallowed — accrual must NEVER perturb the live cutover path.
  def accrue_windowed_shadow(stream, v2_context)
    roster, v_w = TrustIndex::ContextBuilder.windowed_inputs(stream)
    return if v_w.nil? # no CCV snapshots in the window → cannot window (chat & CCV are separate pipelines)

    wctx = v2_context.with(l2_roster_usernames: roster, v_w: v_w)
    wres = TrustIndex::V2::Engine.compute(context: wctx, k: Calibration::Registry.load)
    log_shadow(stream, nil, wres, wctx) # wres.rho_convention == "windowed" (v_w present) → convention=windowed mining
  rescue StandardError => e
    Rails.logger.error("SignalComputeWorker: windowed-shadow accrue failed (stream #{stream.id}) — #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  # OFF by default (flag unregistered/disabled) → byte-identical, no windowed compute. When enabled, each
  # stream is windowed-shadowed once every DUTY SCW cycles, staggered across streams by a deterministic
  # shard so the added CH/PG load spreads evenly (DSV: even always-on is PG +1.5% / CH +13.7%; duty 1/4 →
  # PG +0.4% / CH +3.4%). Duty is a CalibrationConstant (DB-tunable without deploy; fallback 4).
  def windowed_shadow_due?(stream)
    return false unless Flipper.enabled?(:ti_v2_cowindowed_shadow)

    duty = CalibrationConstant.value_for("cowindowed_shadow_duty", fallback: 4).to_i
    return false if duty <= 0

    shard = stream.id.to_s.bytes.sum % duty  # deterministic per-stream (avoids String#hash's per-process seed)
    ((Time.current.to_i / 30) % duty) == shard
  rescue StandardError
    false
  end

  # Run the v2 engine on the live stream (Context reused from the v1 build — no second CH scan) and
  # log the v1↔v2 headline diff for offline validation across the bot-channel cohort before the flip.
  # A v2 defect is swallowed here — shadow must NEVER perturb the live v1 path.
  def shadow_compute_v2(stream, context, v1)
    v2_context = TrustIndex::ContextBuilder.build_v2(stream, context)
    v2 = TrustIndex::V2::Engine.compute(context: v2_context, k: Calibration::Registry.load)
    log_shadow(stream, v1, v2, v2_context)
  rescue StandardError => e
    Rails.logger.error("SignalComputeWorker: v2 shadow failed (stream #{stream.id}) — #{e.message}")
    Sentry.capture_exception(e) if defined?(Sentry)
  end

  # Structured (parseable) shadow-diff line — v1 headline vs v2 headline. Log-only; aggregated across
  # the cohort to validate the v2 engine (does the botter now read RED/AMBER where v1 read "trusted"?).
  # Also carries the GATE-0 calibration observables (v/rho_obs/eihc + the ρ* baseline in effect): with
  # ti_v2_shadow ON, every SCW cycle streams a calibration sample per live channel — the continuous
  # ρ*-mining source (probe `ti-v2-rho-build` = bootstrap; this = steady-state). Cell key is re-derived
  # at mining time from stream_id (category/chat_mode/language live on stream/channel records).
  # v1 is nil on the cutover path (v1 no longer computed) — v1_* keys emit null, same line shape.
  def log_shadow(stream, v1, v2, v2c)
    diff = {
      stream_id: stream.id, channel_id: stream.channel_id,
      v1_ti: v1&.ti_score, v1_erv_percent: v1 ? v1.erv[:erv_percent] : nil,
      v2_erv: v2.erv, v2_authenticity: v2.authenticity,
      v2_band: "#{v2.band&.color}/#{v2.band&.row}", v2_f_hat: v2.f_hat,
      v2_f_hard: v2.f_hard, v2_f_soft: v2.f_soft, # PR3a: fraud-arm breakdown for shadow analysis
      v2_n_frac: v2.n_frac, v2_confirmed_anomaly: v2.confirmed_anomaly,
      # rho_star&.to_f — a DB-resolved cell yields BigDecimal (decimal 6,5) which to_json's as a
      # STRING; keep the mining line type-stable (JSON number) pre- and post-GATE-0 seed (CR N1).
      v2_v: v2c.v, v2_rho_obs: v2.rho_obs, v2_eihc: v2.eihc, v2_rho_star: v2c.cell&.rho_star&.to_f,
      # P0.5: ρ_obs convention ("cumulative"/"windowed") so the ρ* miner segregates samples — the
      # FLIP re-seed must pool ONLY windowed rows (nil on pre-P0.5 lines = cumulative by construction).
      v2_rho_conv: v2.rho_convention,
      # TI v2.1: CcvChatCorrelation value (silent-injection signature) — mined to calibrate
      # phi_inflation on the honest-anchor firing rate BEFORE the dormant C_inflation corroborator is
      # flipped on. Emitted whether or not the corroborator is enabled (observability accrual).
      v2_ccv_chat_divergence: v2c.ccv_chat_divergence
    }
    Rails.logger.info("SCW shadow #{diff.to_json}")
  end

  # Wraps a stage with AS::N instrumentation + Sentry breadcrumb + error capture.
  # AS::N event name = "scw.<stage>" so subscribers (Sentry sidekiq integration,
  # custom log subscribers, future Prometheus exporters) can filter by stage.
  # On exception: tag Sentry scope with stage + stream_id, capture, re-raise so
  # Sidekiq retry semantics remain unchanged.
  def instrument_stage(stage_name, stream_id)
    event_name = "scw.#{stage_name}"
    ActiveSupport::Notifications.instrument(event_name, stream_id: stream_id) do
      if defined?(Sentry)
        Sentry.add_breadcrumb(Sentry::Breadcrumb.new(
          category: "scw.stage",
          message: stage_name,
          data: { stream_id: stream_id },
          level: "info"
        ))
      end
      yield
    end
  rescue StandardError => e
    if defined?(Sentry)
      Sentry.with_scope do |scope|
        scope.set_tags(scw_stage: stage_name, stream_id: stream_id)
        scope.set_fingerprint([ "scw", stage_name, e.class.name ])
        Sentry.capture_exception(e)
      end
    end
    raise
  end

  def throttled?(stream_id)
    ttl = throttle_ttl
    key = "#{THROTTLE_KEY_PREFIX}#{stream_id}"
    acquired = redis.set(key, "1", ex: ttl, nx: true)

    unless acquired
      Rails.logger.debug("SignalComputeWorker: stream #{stream_id} throttled (#{ttl}s)")
      return true
    end

    false
  rescue Redis::BaseError => e
    Rails.logger.warn("SignalComputeWorker: Redis throttle failed (#{e.message}), computing anyway")
    false
  end

  def throttle_ttl
    SignalConfiguration.value_for("signal_compute", "default", "throttle_seconds").to_i
  rescue SignalConfiguration::ConfigurationMissing
    DEFAULT_THROTTLE_SECONDS
  end

  # DEC-7 MF-1: engine-agnostic publish — the Result maps its OWN fields to the wire payload
  # (#to_headline_payload). Default/shadow → v1 legacy shape (unchanged); cutover → v2 NEW contract.
  def publish_update(stream, result)
    return unless result

    payload = result.to_headline_payload.merge(timestamp: Time.current.iso8601).to_json
    redis.publish("#{PUBLISH_CHANNEL_PREFIX}#{stream.channel_id}", payload)
  rescue Redis::BaseError => e
    Rails.logger.warn("SignalComputeWorker: Redis publish failed (#{e.message})")
  end

  # TASK-032 CR #16: Invalidate REST API cache after TI recompute
  def invalidate_api_cache(channel_id)
    %w[headline drill_down full].each do |view|
      Rails.cache.delete("trust:#{channel_id}:#{view}")
      # PR3b SF-5: /erv cache keys are engine-scoped (erv:<engine>:...) — invalidate both variants
      # so the D-8b "fresh on next poll" intent survives the flip in either direction.
      Rails.cache.delete("erv:v1:#{channel_id}:#{view}")
      Rails.cache.delete("erv:v2:#{channel_id}:#{view}")
    end
    Rails.cache.delete("erv:v1:#{channel_id}:details")
    Rails.cache.delete("erv:v2:#{channel_id}:details")
  rescue StandardError => e
    Rails.logger.warn("SignalComputeWorker: cache invalidation failed (#{e.message})")
  end

  def track_signal_health(signal_results)
    nil_count = signal_results.count { |_, r| r.value.nil? }
    ratio = nil_count.to_f / signal_results.size
    redis.set("signal_health:nil_ratio", ratio.round(4), ex: 300)
  rescue Redis::BaseError => e
    Rails.logger.warn("SignalComputeWorker: signal health tracking failed (#{e.message})")
  end

  def redis
    @redis ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1")).tap(&:ping)
  rescue Redis::CannotConnectError => e
    Rails.logger.warn("SignalComputeWorker: Redis unavailable (#{e.message})")
    Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
  end
end
