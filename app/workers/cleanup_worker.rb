# frozen_string_literal: true

# TASK-016 / TASK-033 / TASK-086: single owner of retention for time-series tables.
#
# TASK-086 extension (ADR-086): fat-worker pattern kept (one cron entry = one ops
# contract). `perform` is a thin orchestrator: Flipper guard → session advisory
# lock (spans `perform`, released in ensure) → sequence of `cleanup_old_*` sub-runs
# → auto-disable check. Each sub-run:
#   - reads its retention horizon from SignalConfiguration (no hardcoded const;
#     job-scoped memoization via Current.signal_config — FR-024, zero new cache code)
#   - deletes in BATCH_SIZE batches, each batch in its own transaction with
#     SET LOCAL statement_timeout='30s' (FR-037 — long DELETE → timeout → retry,
#     not a production lock stall)
#   - writes a cleanup_audit_logs row, committed independently (FR-031/038 —
#     best-effort, never raises from the audit write; survives sub-run rollback)
#   - pushes a Prometheus gauge (FR-027..029, fail-soft)
#
# Why a session-level advisory lock (not pg_try_advisory_xact_lock-in-a-transaction):
#   the lock must span all 7 sub-runs, but each sub-run + its audit row must commit
#   independently (otherwise an error in sub-run #5 would roll back #1..#4's deletes
#   AND every audit row, defeating the FR-042 auto-disable trail). pg_advisory_lock
#   (session) gives "lock spans perform" without one giant transaction.
#
# TIH conservation (FR-002/003): never touch the rank-1 (final) TIH per stream,
# never touch rows whose stream is still live (ended_at IS NULL); rows where
# stream_id IS NULL are handled by the defensive orphan pass only (FR-014).

class CleanupWorker
  include Sidekiq::Job

  sidekiq_options queue: :monitoring, retry: 3

  BATCH_SIZE = 1_000
  STATEMENT_TIMEOUT = "30s"
  DEFAULT_RETENTION_DAYS = 90 # last-resort fallback only (SignalConfiguration is the source of truth)
  ADVISORY_LOCK_KEY = "cleanup_worker:daily"
  FLAG = :cleanup_worker

  def perform
    unless Flipper.enabled?(FLAG)
      Rails.logger.info("cleanup_worker: skipped (flag off)")
      record_audit("cleanup_worker", status: :skipped, deleted_count: 0, started_at: Time.current)
      return
    end

    return Rails.logger.info("cleanup_worker: another run in progress, skip") unless acquire_lock

    begin
      run_all_cleanups
      Cleanup::AutoDisableService.check_and_disable!
    ensure
      release_lock
    end
  end

  private

  # --- advisory lock (session-level, spans perform) ---------------------------

  def acquire_lock
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_array([ "SELECT pg_try_advisory_lock(hashtext(?))", ADVISORY_LOCK_KEY ])
    )
  end

  def release_lock
    ApplicationRecord.connection.execute(
      ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", ADVISORY_LOCK_KEY ])
    )
  rescue StandardError => e
    Rails.logger.warn("cleanup_worker: advisory unlock failed — #{e.class}")
  end

  # --- orchestration ----------------------------------------------------------

  def run_all_cleanups
    counts = {
      signals: cleanup_old_signals,
      sessions: cleanup_expired_sessions,
      ccv: cleanup_old_records(CcvSnapshot, "ccv_snapshots"),
      chatters: cleanup_old_records(ChattersSnapshot, "chatters_snapshots"),
      messages: cleanup_old_records(ChatMessage, "chat_messages"),
      tih: cleanup_old_trust_index_histories,
      audit_logs: cleanup_old_audit_logs
    }
    log_summary(counts)
  end

  def log_summary(counts)
    Rails.logger.info(
      "CleanupWorker: deleted #{counts[:signals]} signals, #{counts[:sessions]} sessions, " \
      "#{counts[:ccv]} ccv_snapshots, #{counts[:chatters]} chatters_snapshots, " \
      "#{counts[:messages]} chat_messages, #{counts[:tih]} trust_index_histories, " \
      "#{counts[:audit_logs]} cleanup_audit_logs"
    )
  end

  # --- TIH cleanup (FR-001/004/023): single-SQL window function, batched -------

  def cleanup_old_trust_index_histories
    retention_days = retention_for("trust_index_histories", "default")
    warn_on_low_retention(retention_days)
    cutoff = retention_days.days.ago
    instrumented("tih", retention_days) do
      delete_intermediate_tih(cutoff) + delete_orphan_tih(cutoff)
    end
  end

  def delete_intermediate_tih(cutoff)
    sql = <<~SQL.squish
      DELETE FROM trust_index_histories tih WHERE tih.id IN (
        SELECT id FROM (
          SELECT t.id, ROW_NUMBER() OVER (PARTITION BY t.stream_id ORDER BY t.calculated_at DESC, t.id DESC) AS rn
          FROM trust_index_histories t JOIN streams s ON s.id = t.stream_id
          WHERE s.ended_at IS NOT NULL AND s.ended_at < $1
        ) ranked WHERE rn > 1 LIMIT #{BATCH_SIZE}
      )
    SQL
    batched_loop { ApplicationRecord.connection.exec_update(sql, "cleanup_old_trust_index_histories", [ cutoff ]) }
  end

  def delete_orphan_tih(cutoff)
    batched_loop { TrustIndexHistory.where(stream_id: nil).where(calculated_at: ...cutoff).limit(BATCH_SIZE).delete_all }
  end

  def warn_on_low_retention(retention_days)
    return if retention_days >= DEFAULT_RETENTION_DAYS

    Rails.logger.warn(
      "CleanupWorker: trust_index_histories retention_days=#{retention_days} < #{DEFAULT_RETENTION_DAYS}, " \
      "may break StreamerRatingRefreshWorker RATING_PERIOD invariant. Risk accepted."
    )
  end

  # --- Other time-series tables (FR-019..022) ---------------------------------

  def cleanup_old_signals
    days = retention_for("cleanup", "ti_signals")
    instrumented("ti_signals", days) do
      cutoff = days.days.ago
      batched_loop { TiSignal.where(timestamp: ...cutoff).limit(BATCH_SIZE).delete_all }
    end
  end

  # Generic timestamp-based cleanup. Channels with a per-channel retention override
  # (FR-025) are pruned at their own horizon first, then everything else at the table default.
  def cleanup_old_records(model, table_name)
    instrumented(table_name, retention_for("cleanup", table_name)) do
      override_ids = override_channel_ids
      delete_channels_with_override(model, table_name, override_ids) +
        delete_default_window(model, table_name, override_ids)
    end
  end

  def delete_default_window(model, table_name, override_channel_ids)
    cutoff = retention_for("cleanup", table_name).days.ago
    exclude_stream_ids = override_channel_ids.empty? ? nil : Stream.where(channel_id: override_channel_ids).select(:id)
    batched_loop do
      scope = model.where("#{model.table_name}.timestamp < ?", cutoff).limit(BATCH_SIZE)
      scope = scope.where.not(stream_id: exclude_stream_ids) if exclude_stream_ids
      scope.delete_all
    end
  end

  def delete_channels_with_override(model, table_name, override_channel_ids)
    override_channel_ids.sum do |channel_id|
      cutoff = retention_for("cleanup", "channel:#{channel_id}", fallback_category: table_name).days.ago
      stream_ids = Stream.for_channel(channel_id).select(:id)
      batched_loop { model.where(stream_id: stream_ids).where("#{model.table_name}.timestamp < ?", cutoff).limit(BATCH_SIZE).delete_all }
    end
  end

  def override_channel_ids
    SignalConfiguration.where(signal_type: "cleanup", param_name: "retention_days")
                       .where("category LIKE 'channel:%'")
                       .pluck(:category).map { |c| c.delete_prefix("channel:") }
  end

  def cleanup_expired_sessions
    instrumented("sessions", nil) do
      batched_loop { Session.where(is_active: false).where(expires_at: ...Time.current).limit(BATCH_SIZE).delete_all }
    end
  end

  # cleanup_audit_logs retention is INDEFINITE per PO directive 2026-05-12 — never auto-deleted.
  def cleanup_old_audit_logs
    Rails.logger.info("cleanup_worker: cleanup_audit_logs retention indefinite — skipped")
    record_audit("cleanup_audit_logs", status: :skipped, deleted_count: 0, started_at: Time.current, retention_days: nil)
    0
  end

  # --- batching helper: each batch in its own txn with SET LOCAL statement_timeout

  def batched_loop
    total = 0
    loop do
      affected = ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT}'")
        yield
      end
      total += affected
      break if affected < BATCH_SIZE
    end
    total
  end

  # --- config + audit + metrics ----------------------------------------------

  def retention_for(signal_type, category, fallback_category: nil)
    SignalConfiguration.value_for(signal_type, category, "retention_days").to_i
  rescue SignalConfiguration::ConfigurationMissing
    raise if fallback_category.nil?

    retention_for(signal_type, fallback_category)
  rescue StandardError
    DEFAULT_RETENTION_DAYS
  end

  # Wraps a sub-run: timing, audit row, Prometheus gauge. Returns the deleted count.
  def instrumented(table_name, retention_days)
    started_at = Time.current
    deleted = yield
    record_audit(table_name, status: :success, deleted_count: deleted, started_at: started_at, retention_days: retention_days)
    push_metric(table_name, deleted, Time.current - started_at)
    deleted
  rescue StandardError => e
    finalize_failed_run(table_name, retention_days, started_at, e)
    raise
  end

  def finalize_failed_run(table_name, retention_days, started_at, exception)
    serialized = Cleanup::ErrorSerializer.sanitize(exception, table_name)
    record_audit(table_name, status: :error, deleted_count: 0, started_at: started_at,
                 retention_days: retention_days, error: serialized)
    Rails.logger.error("CleanupWorker: #{table_name} failed — #{serialized['error_code']}")
    # FR-042: check here — perform re-raises before reaching the post-run check,
    # so on the 3rd consecutive error this is the only place the kill switch can trip.
    Cleanup::AutoDisableService.check_and_disable!
  rescue StandardError => e
    Rails.logger.error("cleanup_worker: finalize_failed_run error — #{e.class}")
  end

  def record_audit(table_name, status:, deleted_count:, started_at:, retention_days: nil, error: nil)
    CleanupAuditLog.create!(
      table_name: table_name, run_at: started_at, status: status,
      deleted_count: deleted_count, duration_ms: ((Time.current - started_at) * 1000).to_i,
      retention_days: retention_days, error_code: error&.dig("error_code"), error_context: error&.dig("error_context") || {}
    )
  rescue StandardError => e
    Rails.logger.warn("cleanup_worker: audit_log insert failed — #{e.class}")
    PrometheusMetrics.observe_cleanup_audit_insert_failure(table: table_name)
  end

  def push_metric(table_name, deleted, duration_s)
    consecutive = CleanupAuditLog.recent_for_table(table_name, limit: 3).to_a
                                 .take_while { |row| row.status == "error" }.size
    PrometheusMetrics.observe_cleanup_run(table: table_name, deleted_count: deleted,
                                          duration_seconds: duration_s, consecutive_errors: consecutive)
  rescue StandardError => e
    Rails.logger.warn("cleanup_worker: prometheus push failed — #{e.class}")
  end
end
