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
      TrustIndex::Engine.new.compute(
        signal_results: interaction_output[:results],
        stream: stream,
        ccv: context[:latest_ccv] || 0,
        category: context[:category] || "default"
      )
    end

    # TASK-085 FR-014/015 (ADR-085 D-6 + D-8b): NEW detectors extend AnomalyAlerter pattern.
    # Run AFTER Engine.compute (writes TrustIndexHistory + ErvEstimate) но ДО invalidate_api_cache
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
      "SignalComputeWorker: stream #{stream_id} — TI=#{result.ti_score} ERV=#{result.erv[:erv_percent]}% " \
      "classification=#{result.classification} cold_start=#{result.cold_start[:status]} " \
      "duration=#{duration_ms}ms force=#{force}"
    )
  end

  private

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

  def publish_update(stream, result)
    channel_id = stream.channel_id
    payload = {
      ti_score: result.ti_score,
      classification: result.classification,
      erv_percent: result.erv[:erv_percent],
      erv_count: result.erv[:erv_count],
      label: result.erv[:label],
      label_color: result.erv[:label_color],
      cold_start_status: result.cold_start[:status],
      timestamp: Time.current.iso8601
    }.to_json

    redis.publish("#{PUBLISH_CHANNEL_PREFIX}#{channel_id}", payload)
  rescue Redis::BaseError => e
    Rails.logger.warn("SignalComputeWorker: Redis publish failed (#{e.message})")
  end

  # TASK-032 CR #16: Invalidate REST API cache after TI recompute
  def invalidate_api_cache(channel_id)
    %w[headline drill_down full].each do |view|
      Rails.cache.delete("trust:#{channel_id}:#{view}")
      Rails.cache.delete("erv:#{channel_id}:#{view}")
    end
    Rails.cache.delete("erv:#{channel_id}:details")
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
