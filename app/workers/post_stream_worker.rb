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

      # TASK-037 FR-006: Reputation refresh (must run BEFORE Rating, as Rating may use reputation-adjusted TI)
      StreamerReputationRefreshWorker.perform_async(stream.channel_id)

      # FR-011: Health Score refresh
      HealthScoreRefreshWorker.perform_async(stream.channel_id)

      # FR-012: Streamer Rating refresh
      StreamerRatingRefreshWorker.perform_async(stream.channel_id)

      # TASK-039 FR-046 foundation: snapshot qualifying percentiles в TIH.
      # Delay 2 минуты гарантирует что HS + Reputation refreshes выше успели
      # complete (typically <30s) — snapshot reads fresh latest values.
      Trends::QualifyingPercentileSnapshotWorker.perform_in(2.minutes, stream.id)

      # TASK-039 FR-018: daily aggregation refresh для stream's date.
      # pg_advisory_lock в AggregationWorker защищает от concurrent runs
      # (same channel+date re-triggered при stream part merges, EventSub re-deliveries).
      stream_date = stream.started_at&.to_date&.iso8601
      Trends::AggregationWorker.perform_async(stream.channel_id, stream_date) if stream_date

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
  rescue StandardError => e
    Rails.logger.error("PostStreamWorker: final compute failed for stream #{stream.id} — #{e.message}")
    # If no TI data from live compute either — re-raise for Sidekiq retry.
    # Otherwise continue with last available data from live phase.
    raise unless ti_data_available?(stream)
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

  def build_signals_summary(stream)
    TiSignal.where(stream_id: stream.id)
            .select("DISTINCT ON (signal_type) signal_type, value, confidence, weight_in_ti")
            .order(:signal_type, timestamp: :desc)
            .each_with_object({}) do |sig, summary|
              summary[sig.signal_type] = {
                value: sig.value.to_f,
                confidence: sig.confidence&.to_f,
                weight: sig.weight_in_ti&.to_f
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
