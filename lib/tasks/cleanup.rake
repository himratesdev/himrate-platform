# frozen_string_literal: true

# TASK-086 FR-039/041/048: operator rake tasks for the retention cleanup subsystem.
#
#   rake cleanup:initial_backfill[table,dry_run]
#     One-shot historical cleanup for a single table (chunked, throttled, statement_timeout).
#     dry_run defaults to TRUE — prints a preview (eligible counts + sample) and exits.
#     table ∈ tih | ti_signals | ccv_snapshots | chatters_snapshots | chat_messages
#       rake cleanup:initial_backfill[tih]            # dry-run preview (safe default)
#       rake cleanup:initial_backfill[tih,false]      # actual cleanup
#
#   rake cleanup:report[start_date,end_date,format]   (FR-041)
#     Aggregate cleanup_audit_logs over a date range, per table: runs, total deleted,
#     status breakdown, failure count + failure rate, avg / peak duration_ms.
#     start_date / end_date — ISO-8601 (YYYY-MM-DD) on `run_at`; both optional
#     (omitted = all time). format ∈ text | csv | json, default text.
#       rake cleanup:report                           # all time, text
#       rake cleanup:report[2026-04-01,2026-05-01]    # April, text
#       rake cleanup:report[,,json]                   # all time, json
#       rake cleanup:report[2026-05-01,,csv]          # since May 1, csv
#
#   rake cleanup:restore_from_archive[table,channel_id,dry_run]
#     Restore rows from the R2 cold archive via archive_index. Pending — the cold-archive
#     pipeline (Cleanup::Archive::*) is a follow-up (TASK-A2 carry-over); this task aborts
#     with an explanatory message until it ships.

namespace :cleanup do
  RETENTION_DAYS_DEFAULT = 90
  REPORT_FORMATS = %w[text csv json].freeze

  # PR 1e-B (TASK-251.14): `chat_messages` entry removed — PG table dropped, retention now CH-side.
  TABLE_MAP = {
    "tih" => { model: -> { TrustIndexHistory }, signal_type: "trust_index_histories", category: "default" },
    "ti_signals" => { model: -> { TiSignal }, signal_type: "cleanup", category: "ti_signals" },
    "ccv_snapshots" => { model: -> { CcvSnapshot }, signal_type: "cleanup", category: "ccv_snapshots" },
    "chatters_snapshots" => { model: -> { ChattersSnapshot }, signal_type: "cleanup", category: "chatters_snapshots" }
  }.freeze

  desc "One-shot historical cleanup for one table (chunked, throttled). dry_run defaults to TRUE."
  task :initial_backfill, %i[table dry_run] => :environment do |_t, args|
    spec = TABLE_MAP[args[:table].to_s]
    abort("Invalid table=#{args[:table].inspect}. Valid: #{TABLE_MAP.keys.join(', ')}") unless spec

    dry_run = args[:dry_run].nil? ? true : ActiveModel::Type::Boolean.new.cast(args[:dry_run])
    cutoff = retention_days_for(spec).days.ago

    if args[:table].to_s == "tih"
      Cleanup::BackfillRunner.run_tih(cutoff: cutoff, dry_run: dry_run)
    else
      Cleanup::BackfillRunner.run_table(model: spec[:model].call, cutoff: cutoff, dry_run: dry_run)
    end
  end

  desc "Aggregate cleanup_audit_logs over [start_date,end_date] per table. format ∈ text|csv|json (default text)."
  task :report, %i[start_date end_date format] => :environment do |_t, args|
    # csv/json are stdlib but no longer default gems on Ruby 3.4+ — require lazily
    # (same pattern as lib/tasks/hs_analytics.rake) so loading the rake file never
    # depends on them; only the report task does.
    require "json"
    format = (args[:format].presence || "text").to_s.downcase
    abort("Invalid format=#{args[:format].inspect}. Valid: #{REPORT_FORMATS.join(', ')}") unless REPORT_FORMATS.include?(format)
    require "csv" if format == "csv"

    from = parse_report_date(args[:start_date])
    to = parse_report_date(args[:end_date])
    scope = CleanupAuditLog.all
    scope = scope.where(CleanupAuditLog.arel_table[:run_at].gteq(from.beginning_of_day)) if from
    scope = scope.where(CleanupAuditLog.arel_table[:run_at].lteq(to.end_of_day)) if to

    rows = report_rows(scope)
    render_report(rows, format: format, from: from, to: to)
  end

  desc "Restore rows from the R2 cold archive (pending — cold-archive pipeline is a follow-up)."
  task :restore_from_archive, %i[table channel_id dry_run] => :environment do |_t, _args|
    abort("cleanup:restore_from_archive is not yet available — the R2 cold-archive pipeline " \
          "(Cleanup::Archive::*, archive_index) is a TASK-A2 carry-over (see ADR-086 §4.7). " \
          "Until it ships there is nothing to restore from.")
  end

  # Same retention horizon the worker uses, with the same MIN_RETENTION_DAYS floor —
  # a misconfigured (or deliberately zeroed) admin row can't make the backfill cutoff
  # collapse to "now". CleanupWorker::MIN_RETENTION_DAYS is the single source of truth.
  def retention_days_for(spec)
    raw =
      begin
        SignalConfiguration.value_for(spec[:signal_type], spec[:category], "retention_days").to_i
      rescue StandardError
        RETENTION_DAYS_DEFAULT
      end
    raw.clamp(CleanupWorker::MIN_RETENTION_DAYS..)
  end

  def parse_report_date(value)
    return nil if value.blank?

    Date.iso8601(value.to_s)
  rescue ArgumentError
    abort("Invalid date #{value.inspect} — expected ISO-8601 (YYYY-MM-DD).")
  end

  # One aggregate hash per table_name (sorted), with safe-name field keys.
  def report_rows(scope)
    scope.distinct.pluck(:table_name).sort.map do |table_name|
      table_scope = scope.where(table_name: table_name)
      durations = table_scope.where.not(duration_ms: nil).pluck(:duration_ms)
      runs = table_scope.count
      failures = table_scope.where(status: :error).count
      {
        "table" => table_name,
        "runs" => runs,
        "deleted" => table_scope.sum(:deleted_count).to_i,
        "success" => table_scope.where(status: :success).count,
        "partial" => table_scope.where(status: :partial).count,
        "error" => failures,
        "skipped" => table_scope.where(status: :skipped).count,
        "failure_rate" => runs.zero? ? 0.0 : (failures.to_f / runs).round(4),
        "avg_duration_ms" => durations.empty? ? 0 : (durations.sum / durations.size),
        "peak_duration_ms" => durations.max || 0
      }
    end
  end

  def render_report(rows, format:, from:, to:)
    case format
    when "json"
      puts JSON.pretty_generate({ "range" => { "start" => from&.iso8601, "end" => to&.iso8601 }, "tables" => rows })
    when "csv"
      headers = %w[table runs deleted success partial error skipped failure_rate avg_duration_ms peak_duration_ms]
      puts CSV.generate { |csv|
        csv << headers
        rows.each { |r| csv << headers.map { |h| r[h] } }
      }
    else
      range = "#{from&.iso8601 || 'beginning'} .. #{to&.iso8601 || 'now'}"
      puts "cleanup_audit_logs summary (#{range}):"
      if rows.empty?
        puts "  (no rows)"
      else
        rows.each do |r|
          puts "  #{r['table']}: runs=#{r['runs']} deleted=#{r['deleted']} " \
               "statuses={success:#{r['success']}, partial:#{r['partial']}, error:#{r['error']}, skipped:#{r['skipped']}} " \
               "failure_rate=#{r['failure_rate']} avg_ms=#{r['avg_duration_ms']} peak_ms=#{r['peak_duration_ms']}"
        end
      end
    end
  end
end
