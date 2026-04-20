# frozen_string_literal: true

# TASK-030: Signal Compute Worker.
# Orchestrates full pipeline: context → signals → interaction → anomaly → TI/ERV → persist → publish.
# Triggered by StreamMonitorWorker (live, per stream) and BotScoringWorker (final, post-stream).
# Throttle from DB (signal_configurations). Flipper[:signal_compute] gate.

class SignalComputeWorker
  include Sidekiq::Job
  sidekiq_options queue: :signals, retry: 3

  THROTTLE_KEY_PREFIX = "signal_compute:throttle:"
  PUBLISH_CHANNEL_PREFIX = "ti:updates:"
  DEFAULT_THROTTLE_SECONDS = 30

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
    context = TrustIndex::ContextBuilder.build(stream)

    # FR-004: Full pipeline
    signal_results = TrustIndex::Signals::Registry.compute_all(context)
    interaction_output = TrustIndex::Signals::InteractionMatrix.apply(signal_results)
    # TASK-039 FR-019: enqueue attribution pipeline для каждой созданной anomaly.
    # AnomalyAlerter returns Array anomaly IDs (newly created, после dedup).
    anomaly_ids = TrustIndex::Signals::AnomalyAlerter.check(stream, interaction_output[:results])
    anomaly_ids.each { |id| Trends::AnomalyAttributionWorker.perform_async(id) }

    result = TrustIndex::Engine.new.compute(
      signal_results: interaction_output[:results],
      stream: stream,
      ccv: context[:latest_ccv] || 0,
      category: context[:category] || "default"
    )

    # TASK-032 CR #16: Explicit cache invalidation after TI compute
    invalidate_api_cache(stream.channel_id)

    # FR-005: Redis publish
    publish_update(stream, result)

    # FR-010: Signal health tracking
    track_signal_health(signal_results)

    duration_ms = ((Time.current - started_at) * 1000).to_i
    Rails.logger.info(
      "SignalComputeWorker: stream #{stream_id} — TI=#{result.ti_score} ERV=#{result.erv[:erv_percent]}% " \
      "classification=#{result.classification} cold_start=#{result.cold_start[:status]} " \
      "duration=#{duration_ms}ms force=#{force}"
    )
  end

  private

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
    Rails.cache.delete("health_score:#{channel_id}")
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
