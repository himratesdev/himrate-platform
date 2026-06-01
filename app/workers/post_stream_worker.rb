# frozen_string_literal: true

# TASK-033 FR-001..003: Post-stream pipeline orchestrator.
# Triggered by StreamOfflineWorker after stream finalization.
# Pipeline: final compute → post_stream_report → notifications → HS/Rating refresh.

class PostStreamWorker
  include Sidekiq::Job
  sidekiq_options queue: :post_stream, retry: 3

  LOCK_KEY_PREFIX = "post_stream:lock:"
  LOCK_TTL = 120 # seconds

  sidekiq_retries_exhausted do |job, ex|
    stream = Stream.find_by(id: job["args"].first)
    if stream
      Anomaly.create!(
        stream: stream,
        timestamp: Time.current,
        anomaly_type: "compute_failure",
        details: { error: ex.class.name, message: ex.message, phase: "post_stream", job_id: job["jid"] }
      )
      Rails.logger.error("PostStreamWorker: exhausted retries for stream #{stream.id} — #{ex.message}")
    end
  rescue StandardError => e
    Rails.logger.error("PostStreamWorker: dead letter failed — #{e.message}")
  end

  def perform(stream_id)
    stream = Stream.find_by(id: stream_id)
    unless stream
      Rails.logger.warn("PostStreamWorker: stream #{stream_id} not found")
      return
    end

    # Redis lock to prevent concurrent processing of same stream
    return unless acquire_lock(stream_id)

    started_at = Time.current

    begin
      # FR-002: Final TI/ERV compute (synchronous, force=true skips throttle)
      run_final_compute(stream)

      # FR-003: Generate post_stream_report
      report = generate_report(stream)

      # FR-007: TI Divergence check (merged streams only)
      TiDivergenceAlerter.check(stream) if stream.merged_parts_count > 1

      # FR-006: Broadcast stream_ended via Action Cable
      PostStreamNotificationService.broadcast_stream_ended(stream, report)

      # FR-009: Schedule expiring warning (17h after offline)
      schedule_expiring_warning(stream)

      # TASK-037 FR-006: Reputation refresh
      StreamerReputationRefreshWorker.perform_async(stream.channel_id)

      # EPIC ML-FEATURE-EXTRACTOR PR1: persist per-stream LightGBM-ready feature vector.
      # Async (queue :post_stream) — no downstream worker depends on the row being ready
      # immediately; ML training queries window 24h+ data. Idempotent at worker level.
      MlFeatureExtractionWorker.perform_async(stream.id)

      # TASK-086 FR-032: refresh the latest_tih_per_stream MV (per-stream final TIH).
      # No stream arg — REFRESH ... CONCURRENTLY is a full refresh, not per-stream
      # incremental. The 2-min delay ensures the final compute above committed; the
      # advisory-lock dedup in the worker collapses many ended streams into one
      # REFRESH at prime time (the no-arg fan-in is intentional and keeps it cheap).
      Trends::LatestTihRefreshWorker.perform_in(2.minutes)

      # TASK-039 FR-018: daily aggregation refresh для stream's date.
      # pg_advisory_lock в AggregationWorker защищает от concurrent runs
      # (same channel+date re-triggered при stream part merges, EventSub re-deliveries).
      stream_date = stream.started_at&.to_date&.iso8601
      Trends::AggregationWorker.perform_async(stream.channel_id, stream_date) if stream_date

      # TASK-039 FR-036: Invalidate Trends API cache для этого канала.
      # O(1) INCR epoch в Redis → все cached responses этого канала становятся stale
      # при следующем request. Graceful degradation если Redis fails (cache самоинвалидируется
      # по TTL 30m-24h, error reported via Rails.error.report).
      Trends::Cache::Invalidator.call(stream.channel_id)

      duration_ms = ((Time.current - started_at) * 1000).to_i
      Rails.logger.info(
        "PostStreamWorker: stream #{stream_id} — " \
        "TI=#{report&.trust_index_final} ERV=#{report&.erv_percent_final}% " \
        "merged=#{stream.merged_parts_count > 1} parts=#{stream.merged_parts_count} " \
        "duration=#{duration_ms}ms"
      )
    ensure
      release_lock(stream_id)
    end
  end

  private

  def run_final_compute(stream)
    SignalComputeWorker.new.perform(stream.id, true)
    detect_silent_skip!(stream)
  rescue StandardError => e
    Rails.logger.error("PostStreamWorker: final compute failed for stream #{stream.id} — #{e.message}")
    # If no TI data from live compute either — re-raise for Sidekiq retry.
    # Otherwise continue with last available data from live phase.
    raise unless ti_data_available?(stream)
  end

  # BUG-SIGNAL-COMPUTE-SILENT-SKIP (2026-06-01): after the inline SignalComputeWorker call
  # returns, verify that TI compute actually happened. The worker short-circuits silently
  # on `:signal_compute` flag-off (which happens during backfill / pause windows), losing
  # post-stream TI finalization forever — PSR ends up with trust_index_final=NULL and the
  # stream never gets TIH. Defence: if no TIH rows exist for this stream after the inline
  # call AND the flag is currently disabled, record an Anomaly for visibility and schedule
  # a deferred retry that will succeed once the flag is flipped back ON.
  def detect_silent_skip!(stream)
    return if ti_data_available?(stream)
    return if Flipper.enabled?(:signal_compute) # flag is ON — likely legitimate empty stream (no chatters/signals)

    Rails.logger.warn(
      "PostStreamWorker: silent skip detected for stream #{stream.id} " \
      "— :signal_compute flag OFF, no TIH after inline compute. Scheduling 1h deferred retry."
    )
    Anomaly.create!(
      stream: stream,
      timestamp: Time.current,
      anomaly_type: "compute_failure",
      details: {
        reason: "signal_compute_flag_off_at_finalization",
        retry_scheduled_at: 1.hour.from_now.iso8601,
        # CR iter-2 N1: Sidekiq::Context.current["jid"] is canonical (matches the pattern used
        # by SignalComputeWorker's sidekiq_retries_exhausted block which reads job["jid"]).
        # `defined?(Sidekiq::Context)` guards against spec/rake-harness contexts where the
        # context module isn't initialized (returns nil safely instead of NameError).
        post_stream_worker_jid: (defined?(Sidekiq::Context) ? Sidekiq::Context.current["jid"] : nil)
      }
    )
    # Schedule deferred async retry — by the time it runs the flag should be back on.
    # force=true so the retry bypasses throttle once it executes.
    #
    # CR iter-2 S1 follow-up: the deferred retry at T+1h ALSO hits the flag-off short-circuit
    # in SignalComputeWorker#perform if the flag is still OFF (e.g., long-running backfill).
    # When that happens, no second Anomaly is created and operators don't know the recovery
    # was eaten. Out of scope for this PR — tracked in BUG-SIGNAL-COMPUTE-SILENT-SKIP follow-up
    # ticket. Mitigation today: the original Anomaly above gives operators a manual rerun handle.
    SignalComputeWorker.perform_in(1.hour, stream.id, true)
  rescue StandardError => e
    Rails.logger.error(
      "PostStreamWorker: detect_silent_skip! failed for stream #{stream.id} — #{e.class}: #{e.message}"
    )
    # Non-fatal — original perform() should continue with whatever live-phase TI is available.
  end

  def ti_data_available?(stream)
    TrustIndexHistory.where(stream_id: stream.id).exists?
  end

  def generate_report(stream)
    ti_history = TrustIndexHistory.where(stream_id: stream.id)
                                  .order(calculated_at: :desc)
                                  .first

    signals_summary = build_signals_summary(stream)
    anomalies_data = Anomaly.where(stream_id: stream.id)
                            .select(:anomaly_type, :cause, :ccv_impact, :confidence, :timestamp)
                            .map { |a| a.attributes.except("id") }

    erv_data = if ti_history
                  TrustIndex::ErvCalculator.compute(
                    ti_score: ti_history.trust_index_score.to_f,
                    ccv: ti_history.ccv.to_i,
                    confidence: ti_history.confidence.to_f
                  )
    end

    attrs = {
      trust_index_final: ti_history&.trust_index_score,
      erv_percent_final: ti_history&.erv_percent,
      erv_final: erv_data&.dig(:erv_count),
      ccv_peak: stream.peak_ccv,
      ccv_avg: stream.avg_ccv,
      duration_ms: stream.duration_ms,
      signals_summary: signals_summary,
      anomalies: anomalies_data,
      generated_at: Time.current
    }

    # UPSERT: update if already exists (merged stream re-finalization)
    report = PostStreamReport.find_or_initialize_by(stream_id: stream.id)
    report.update!(attrs)
    report
  end

  # BUG-TI-SIGNAL-BREAKDOWN (2026-06-01): read signals from latest TIH.signal_breakdown
  # JSON column. The `signals` PG table is dead-write since TrustIndex::Engine refactor;
  # TiSignal.where lookups returned 0 rows → post-stream reports stored an empty summary.
  # Same fix pattern as Trust::ShowService#signal_breakdown_for_stream.
  def build_signals_summary(stream)
    tih = TrustIndexHistory.where(stream_id: stream.id).order(calculated_at: :desc).first
    return {} unless tih

    breakdown = tih.signal_breakdown
    return {} unless breakdown.is_a?(Hash)

    breakdown.each_with_object({}) do |(signal_type, data), summary|
      next unless data.is_a?(Hash)
      summary[signal_type] = {
        value: data["value"]&.to_f,
        confidence: data["confidence"]&.to_f,
        weight: data["weight"]&.to_f
      }
    end
  end

  def schedule_expiring_warning(stream)
    return unless stream.ended_at

    warning_time = stream.ended_at + 17.hours
    return if warning_time <= Time.current # Already past warning time

    StreamExpiringWorker.perform_at(warning_time, stream.id)
  end

  def acquire_lock(stream_id)
    acquired = Sidekiq.redis do |conn|
      conn.set("#{LOCK_KEY_PREFIX}#{stream_id}", "1", ex: LOCK_TTL, nx: true)
    end
    unless acquired
      Rails.logger.info("PostStreamWorker: stream #{stream_id} already being processed, skipping")
      return false
    end
    true
  rescue Redis::BaseError => e
    Rails.logger.warn("PostStreamWorker: Redis lock failed (#{e.message}), proceeding anyway")
    true
  end

  def release_lock(stream_id)
    Sidekiq.redis { |conn| conn.del("#{LOCK_KEY_PREFIX}#{stream_id}") }
  rescue Redis::BaseError
    # Best effort
  end
end
