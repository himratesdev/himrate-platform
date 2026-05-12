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
#   rake cleanup:report[table]
#     Print a summary from cleanup_audit_logs (deleted totals, statuses, avg/peak duration).
#     table optional — all tables if omitted.
#
#   rake cleanup:restore_from_archive[table,channel_id,dry_run]
#     Restore rows from the R2 cold archive via archive_index. Pending — the cold-archive
#     pipeline (Cleanup::Archive::*) is a follow-up (TASK-A2 carry-over); this task aborts
#     with an explanatory message until it ships.

namespace :cleanup do
  RETENTION_DAYS_DEFAULT = 90

  TABLE_MAP = {
    "tih" => { model: -> { TrustIndexHistory }, signal_type: "trust_index_histories", category: "default" },
    "ti_signals" => { model: -> { TiSignal }, signal_type: "cleanup", category: "ti_signals" },
    "ccv_snapshots" => { model: -> { CcvSnapshot }, signal_type: "cleanup", category: "ccv_snapshots" },
    "chatters_snapshots" => { model: -> { ChattersSnapshot }, signal_type: "cleanup", category: "chatters_snapshots" },
    "chat_messages" => { model: -> { ChatMessage }, signal_type: "cleanup", category: "chat_messages" }
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

  desc "Print a summary from cleanup_audit_logs (optional [table] filter)."
  task :report, %i[table] => :environment do |_t, args|
    scope = args[:table].present? ? CleanupAuditLog.where(table_name: args[:table]) : CleanupAuditLog.all
    puts "cleanup_audit_logs summary#{" — table=#{args[:table]}" if args[:table].present?}:"
    table_names = scope.distinct.pluck(:table_name)
    if table_names.empty?
      puts "  (no rows)"
      next
    end
    table_names.sort.each do |table_name|
      rows = CleanupAuditLog.where(table_name: table_name)
      durations = rows.where.not(duration_ms: nil).pluck(:duration_ms)
      puts "  #{table_name}: runs=#{rows.count} deleted=#{rows.sum(:deleted_count)} " \
           "statuses=#{rows.group(:status).count} " \
           "avg_ms=#{durations.empty? ? 0 : (durations.sum / durations.size)} peak_ms=#{durations.max || 0}"
    end
  end

  desc "Restore rows from the R2 cold archive (pending — cold-archive pipeline is a follow-up)."
  task :restore_from_archive, %i[table channel_id dry_run] => :environment do |_t, _args|
    abort("cleanup:restore_from_archive is not yet available — the R2 cold-archive pipeline " \
          "(Cleanup::Archive::*, archive_index) is a TASK-A2 carry-over (see ADR-086 §4.7). " \
          "Until it ships there is nothing to restore from.")
  end

  def retention_days_for(spec)
    SignalConfiguration.value_for(spec[:signal_type], spec[:category], "retention_days").to_i
  rescue StandardError
    RETENTION_DAYS_DEFAULT
  end
end
