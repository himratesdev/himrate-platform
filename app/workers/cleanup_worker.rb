# frozen_string_literal: true

# TASK-016 / TASK-033 / TASK-086: single owner of retention for time-series tables.
#
# TASK-086 extension (ADR-086): fat-worker pattern kept (one cron entry = one ops
# contract). `perform` is a thin orchestrator: Flipper guard → session advisory
# lock (spans `perform`, released in ensure) → sequence of `cleanup_old_*` sub-runs
# → weekly table-row stat push → auto-disable check → worker heartbeat metric.
# Each sub-run:
#   - reads its retention horizon from SignalConfiguration (no hardcoded const;
#     job-scoped memoization via Current.signal_config — FR-024, zero new cache code),
#     then floors it at MIN_RETENTION_DAYS so a misconfigured `retention_days = 0` admin
#     row can never push a cutoff to "now" (uniform across all 4 time-series tables —
#     ti_signals/ccv_snapshots/chatters_snapshots + trust_index_histories special-cased)
#   - deletes in BATCH_SIZE batches, each batch in its own transaction with
#     SET LOCAL statement_timeout='30s' (FR-037 — long DELETE → timeout → retry,
#     not a production lock stall). A timeout AFTER ≥1 committed batch → status
#     `partial` (FR-031); a timeout with zero progress → status `error`.
#   - writes a cleanup_audit_logs row, committed independently (FR-031/038 —
#     best-effort, never raises from the audit write; survives sub-run rollback)
#   - pushes a Prometheus gauge (FR-027..029, fail-soft)
#   - on error: writes an `error` audit row, pushes the consecutive-errors gauge,
#     and CONTINUES to the next sub-run (FR-031 "best-effort, per sub-run") — the
#     daily TIH cleanup (the pre-launch blocker) is never starved by an earlier
#     sub-run failing. At the end of `perform`, if ANY sub-run errored, the worker
#     re-raises an aggregated error so Sidekiq retry / monitoring sees it — but
#     only AFTER every sub-run got its attempt.
#
# Why a session-level advisory lock (not pg_try_advisory_xact_lock-in-a-transaction):
#   the lock must span all sub-runs, but each sub-run + its audit row must commit
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
  # Hard floor for EVERY per-table retention horizon — a misconfigured (or deliberately
  # zeroed) admin row must never push a cutoff to "now". For trust_index_histories the
  # FR-002/003 conservation rule additionally protects final/live rows; the other three
  # tables (ti_signals, ccv_snapshots, chatters_snapshots) have no conservation rule, so
  # this floor is their only guard against a full-table wipe. PR 1e-B (2026-06-01) dropped
  # chat_messages from the cleanup set — retention now CH-side (MergeTree TTL).
  # Single source of truth — referenced from lib/tasks/cleanup.rake and the
  # SignalConfiguration model validation; do not duplicate the literal.
  MIN_RETENTION_DAYS = 7
  ADVISORY_LOCK_KEY = "cleanup_worker:daily"
  FLAG = :cleanup_worker
  HEARTBEAT_TABLE = "cleanup_worker" # grouping label for the per-perform heartbeat metric
  ROW_STATS_WDAY = 0 # weekly cadence for cleanup_worker_table_rows (Sunday) — ADR-086 §4.4

  class SubRunFailures < StandardError; end

  def perform
    unless Flipper.enabled?(FLAG)
      Rails.logger.info("cleanup_worker: skipped (flag off)")
      record_audit("cleanup_worker", status: :skipped, deleted_count: 0, started_at: Time.current)
      push_worker_heartbeat(0, 0)
      return
    end

    return Rails.logger.info("cleanup_worker: another run in progress, skip") unless acquire_lock

    started_at = Time.current
    begin
      counts, errors = run_all_cleanups
      push_table_row_stats
      Cleanup::AutoDisableService.check_and_disable!
      push_worker_heartbeat(counts.values.sum, Time.current - started_at)
      raise SubRunFailures, "cleanup sub-runs failed: #{errors.join(', ')}" if errors.any?
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

  # Runs every sub-run, isolating each one's failure (FR-031). Returns
  # [counts_hash, failed_table_names]. A failed sub-run contributes 0 to counts.
  def run_all_cleanups
    errors = []
    counts = {}
    sub_runs.each do |key, runnable|
      counts[key] = runnable.call
    rescue StandardError => e
      errors << key.to_s
      Rails.logger.error("cleanup_worker: sub-run #{key} failed — #{e.class}")
      counts[key] = 0
    end
    log_summary(counts)
    [ counts, errors ]
  end

  def sub_runs
    # PR 1e-B (TASK-251.14): :messages retention removed — chat_messages PG table dropped.
    # Chat retention now ClickHouse-managed (TTL on MergeTree, see clickhouse/schema.rb).
    {
      signals: -> { cleanup_old_signals },
      sessions: -> { cleanup_expired_sessions },
      ccv: -> { cleanup_old_records(CcvSnapshot, "ccv_snapshots") },
      chatters: -> { cleanup_old_records(ChattersSnapshot, "chatters_snapshots") },
      tih: -> { cleanup_old_trust_index_histories },
      audit_logs: -> { cleanup_old_audit_logs }
    }
  end

  def log_summary(counts)
    Rails.logger.info(
      "CleanupWorker: deleted #{counts[:signals]} signals, #{counts[:sessions]} sessions, " \
      "#{counts[:ccv]} ccv_snapshots, #{counts[:chatters]} chatters_snapshots, " \
      "#{counts[:tih]} trust_index_histories, " \
      "#{counts[:audit_logs]} cleanup_audit_logs"
    )
  end

  # --- TIH cleanup (FR-001/004/023): single-SQL window function, batched -------

  def cleanup_old_trust_index_histories
    retention_days = retention_for("trust_index_histories", "default") # floored at MIN_RETENTION_DAYS inside retention_for
    warn_on_low_retention(retention_days)
    cutoff = retention_days.days.ago
    instrumented("tih", retention_days) do
      n = delete_intermediate_tih(cutoff)
      with_prior(n) { delete_orphan_tih(cutoff) }
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
      "CleanupWorker: trust_index_histories retention_days=#{retention_days} < #{DEFAULT_RETENTION_DAYS}. " \
      "Reduced retention may impact downstream analytics windows. Risk accepted."
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
      n = delete_channels_with_override(model, table_name, override_ids)
      with_prior(n) { delete_default_window(model, table_name, override_ids) }
    end
  end

  def delete_default_window(model, table_name, override_channel_ids)
    cutoff = retention_for("cleanup", table_name).days.ago
    override_stream_ids = override_channel_ids.empty? ? nil : Stream.where(channel_id: override_channel_ids).select(:id)
    batched_loop do
      scope = model.where("#{model.table_name}.timestamp < ?", cutoff).limit(BATCH_SIZE)
      # NULL-stream_id rows must still be pruned at the default window even when a
      # per-channel override exists — `NOT IN (… NULL …)` is NULL for NULL stream_id
      # (would orphan e.g. ccv_snapshots with no stream). Include them explicitly.
      scope = scope.where("#{model.table_name}.stream_id IS NULL OR #{model.table_name}.stream_id NOT IN (?)", override_stream_ids) if override_stream_ids
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

  # Runs the DELETE in BATCH_SIZE batches. If a batch is killed by the
  # statement_timeout AFTER ≥1 prior batch committed → raises Cleanup::PartialRunError
  # carrying the rows-so-far (→ status partial). If killed on the first batch (zero
  # progress) → re-raises the QueryCanceled (→ status error).
  def batched_loop
    total = 0
    loop do
      affected =
        begin
          ApplicationRecord.transaction do
            ApplicationRecord.connection.execute("SET LOCAL statement_timeout = '#{STATEMENT_TIMEOUT}'")
            yield
          end
        rescue ActiveRecord::QueryCanceled
          raise if total.zero?

          raise Cleanup::PartialRunError, total
        end
      total += affected
      break if affected < BATCH_SIZE
    end
    total
  end

  # Re-raise a PartialRunError from a *second* batched section with the first
  # section's full count folded in (so the audit row's deleted_count is accurate
  # for sub-runs that run two batched DELETEs).
  def with_prior(prior_count)
    prior_count + yield
  rescue Cleanup::PartialRunError => e
    raise Cleanup::PartialRunError, prior_count + e.deleted_count
  end

  # --- config + audit + metrics ----------------------------------------------

  # Retention horizon (days) from SignalConfiguration, floored at MIN_RETENTION_DAYS.
  # Every cutoff in this worker goes through here — a misconfigured (or deliberately
  # zeroed) admin row can never collapse a retention window to "now".
  def retention_for(signal_type, category, fallback_category: nil)
    raw_retention_for(signal_type, category, fallback_category: fallback_category).clamp(MIN_RETENTION_DAYS..)
  end

  def raw_retention_for(signal_type, category, fallback_category: nil)
    SignalConfiguration.value_for(signal_type, category, "retention_days").to_i
  rescue SignalConfiguration::ConfigurationMissing
    raise if fallback_category.nil?

    raw_retention_for(signal_type, fallback_category)
  rescue StandardError
    DEFAULT_RETENTION_DAYS
  end

  # Wraps a sub-run: timing, audit row, Prometheus gauge. Returns the deleted count.
  # PartialRunError → status partial with the rows actually deleted; any other
  # exception → finalize_failed_run (status error) then re-raise so run_all_cleanups
  # records the failure and continues.
  def instrumented(table_name, retention_days)
    started_at = Time.current
    deleted = yield
    record_audit(table_name, status: :success, deleted_count: deleted, started_at: started_at, retention_days: retention_days)
    push_metric(table_name, deleted, Time.current - started_at, consecutive_errors: 0)
    deleted
  rescue Cleanup::PartialRunError => e
    finalize_partial_run(table_name, retention_days, started_at, e)
    e.deleted_count
  rescue StandardError => e
    finalize_failed_run(table_name, retention_days, started_at, e)
    raise
  end

  def finalize_partial_run(table_name, retention_days, started_at, partial)
    record_audit(table_name, status: :partial, deleted_count: partial.deleted_count, started_at: started_at,
                 retention_days: retention_days,
                 error: { "error_code" => "57014", "error_context" => { "table" => table_name, "reason" => "statement_timeout", "deleted_count" => partial.deleted_count } })
    push_metric(table_name, partial.deleted_count, Time.current - started_at, consecutive_errors: 0)
    Rails.logger.warn("CleanupWorker: #{table_name} partial — statement_timeout after #{partial.deleted_count} rows")
  rescue StandardError => e
    Rails.logger.error("cleanup_worker: finalize_partial_run error — #{e.class}")
  end

  def finalize_failed_run(table_name, retention_days, started_at, exception)
    serialized = Cleanup::ErrorSerializer.sanitize(exception, table_name)
    record_audit(table_name, status: :error, deleted_count: 0, started_at: started_at,
                 retention_days: retention_days, error: serialized)
    push_metric(table_name, 0, Time.current - started_at, consecutive_errors: consecutive_errors_for(table_name))
    Rails.logger.error("CleanupWorker: #{table_name} failed — #{serialized['error_code']}")
    # FR-042: also check here — auto-disable can trip on the 3rd consecutive error
    # even though run_all_cleanups continues past this sub-run.
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

  # consecutive error audit rows for this table, INCLUDING the row just written by
  # the current failed run (record_audit ran before this in finalize_failed_run).
  def consecutive_errors_for(table_name)
    CleanupAuditLog.recent_for_table(table_name, limit: Cleanup::AutoDisableService::CONSECUTIVE_ERROR_THRESHOLD).to_a
                   .take_while { |row| row.status == "error" }.size
  end

  def push_metric(table_name, deleted, duration_s, consecutive_errors:)
    PrometheusMetrics.observe_cleanup_run(table: table_name, deleted_count: deleted,
                                          duration_seconds: duration_s, consecutive_errors: consecutive_errors)
  rescue StandardError => e
    Rails.logger.warn("cleanup_worker: prometheus push failed — #{e.class}")
  end

  # FR-030 safety-net target: a single per-`perform` heartbeat gauge
  # (cleanup_worker_last_run_timestamp_seconds{table="cleanup_worker"}) so the
  # Alertmanager rule "worker hasn't run in 7d" has one series to watch. Pushed on
  # every `perform`, including a Flipper-skipped run (the worker DID run).
  def push_worker_heartbeat(total_deleted, duration_s)
    push_metric(HEARTBEAT_TABLE, total_deleted, duration_s, consecutive_errors: 0)
  end

  # FR-029: weekly (Sunday) per-table row-count gauges for the Grafana trend panel.
  # `total` uses the PG planner estimate (O(1), exact value irrelevant for a trend);
  # TIH also gets final (from the latest_tih_per_stream MV) / live / intermediate kinds.
  def push_table_row_stats
    return unless Date.current.wday == ROW_STATS_WDAY

    push_tih_row_stats
    # PR 1e-B: chat_messages dropped — table-row stats now ClickHouse-side (see Grafana CH dashboards).
    { "ti_signals" => TiSignal, "ccv_snapshots" => CcvSnapshot,
      "chatters_snapshots" => ChattersSnapshot }.each do |name, model|
      PrometheusMetrics.observe_cleanup_table_rows(table: name, kind: "total", rows: estimated_rows(model.table_name))
    end
  rescue StandardError => e
    Rails.logger.warn("cleanup_worker: table-row stats push failed — #{e.class}")
  end

  def push_tih_row_stats
    total = estimated_rows("trust_index_histories")
    final = LatestTihPerStream.count
    live = TrustIndexHistory.joins(:stream).where(streams: { ended_at: nil }).count
    intermediate = [ total - final - live, 0 ].max
    PrometheusMetrics.observe_cleanup_table_rows(table: "trust_index_histories", kind: "total", rows: total)
    PrometheusMetrics.observe_cleanup_table_rows(table: "trust_index_histories", kind: "final", rows: final)
    PrometheusMetrics.observe_cleanup_table_rows(table: "trust_index_histories", kind: "live", rows: live)
    PrometheusMetrics.observe_cleanup_table_rows(table: "trust_index_histories", kind: "intermediate", rows: intermediate)
  end

  def estimated_rows(table_name)
    ApplicationRecord.connection.select_value(
      ApplicationRecord.sanitize_sql_array([ "SELECT reltuples::bigint FROM pg_class WHERE oid = ?::regclass", table_name ])
    ).to_i.clamp(0, Float::INFINITY).to_i
  rescue StandardError
    0
  end
end
