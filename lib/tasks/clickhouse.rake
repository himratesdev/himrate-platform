# frozen_string_literal: true

# TASK-251.14 (PR 1a): ClickHouse schema provisioning + liveness.
# The applier itself (file discovery + statement splitting) lives in Clickhouse::Schema
# (app/services/clickhouse/schema.rb) so it is unit-tested and nothing leaks onto Object.
namespace :clickhouse do
  desc "Create/upgrade ClickHouse tables & views (idempotent; applies db/clickhouse/*.sql in order)"
  task setup: :environment do
    client = Clickhouse.client
    files = Clickhouse::Schema.files
    abort "✗ No ClickHouse schema files in #{Clickhouse::Schema::DIR}" if files.empty?

    files.each do |path|
      statements = Clickhouse::Schema.statements(File.read(path))
      statements.each do |stmt|
        client.execute(stmt)
      rescue Clickhouse::Error => e
        abort "✗ #{File.basename(path)}: #{e.message}"
      end
      puts "✓ applied #{File.basename(path)} (#{statements.size} statement(s))"
    end
    puts "ClickHouse schema setup complete on #{client.database} @ #{client.host}:#{client.port}"
  end

  desc "Ping ClickHouse (/ping) — exits non-zero if unreachable"
  task ping: :environment do
    c = Clickhouse.client
    abort "✗ ClickHouse NOT reachable @ #{c.host}:#{c.port}" unless c.ping

    puts "✓ ClickHouse reachable @ #{c.host}:#{c.port}/#{c.database}"
  end

  # TASK-251.14c: one-shot full backfill of historical Postgres chat_messages into ClickHouse, up to
  # a T0 watermark (the timestamp at which the live dual-write was enabled in this env). Post-T0
  # rows are already covered by ChatMessageWorker#mirror_to_clickhouse, so the cutoff prevents
  # duplicates with the live mirror. Idempotent + resumable (Redis cursor); kill-switch via Flipper
  # :chat_backfill_running — flip OFF to pause cleanly (cursor preserved).
  desc "Backfill historical chat_messages PG → CH up to T0 watermark (resumable; gated by :chat_backfill_running)"
  task :backfill_chat, %i[t0_iso batch_size sleep_seconds] => :environment do |_, args|
    if args.t0_iso.blank?
      abort "Usage: rake 'clickhouse:backfill_chat[T0_ISO,BATCH_SIZE,SLEEP_S]' " \
            "(e.g. clickhouse:backfill_chat[2026-05-28T03:29:10Z,5000,0.5])"
    end

    t0 = Time.parse(args.t0_iso)
    abort "✗ T0 (#{t0.iso8601}) is in the future — backfill watermark must be the dual-write enable time, in the past" if t0 > Time.current

    unless Flipper.enabled?(:chat_backfill_running)
      abort "✗ Flipper :chat_backfill_running is OFF — enable it before running the backfill " \
            "(`Flipper.enable(:chat_backfill_running)` is the kill-switch; flip OFF mid-run to pause)"
    end

    batch_size = (args.batch_size || Clickhouse::ChatBackfill::DEFAULT_BATCH_SIZE).to_i
    sleep_seconds = (args.sleep_seconds || Clickhouse::ChatBackfill::DEFAULT_SLEEP_SECONDS).to_f

    result = Clickhouse::ChatBackfill.call(t0: t0, batch_size: batch_size, sleep_seconds: sleep_seconds)
    puts "ChatBackfill: status=#{result.status} rows=#{result.rows_processed} batches=#{result.batches} elapsed=#{result.elapsed_seconds}s"
    abort "✗ backfill ended with status=#{result.status}" unless %w[done paused].include?(result.status)
  end

  desc "Show ClickHouse chat-backfill progress (Redis state — read-only)"
  task backfill_chat_status: :environment do
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    prefix = Clickhouse::ChatBackfill::REDIS_PREFIX
    puts "t0:             #{redis.get("#{prefix}:t0") || '(unset)'}"
    puts "cursor_id:      #{redis.get("#{prefix}:cursor_id") || '(unset — will start at NULL_UUID)'}"
    puts "rows_processed: #{redis.get("#{prefix}:rows_processed") || '0'}"
    puts "status:         #{redis.get("#{prefix}:status") || '(never run)'}"
    last_error = redis.get("#{prefix}:last_error")
    puts "last_error:     #{last_error}" if last_error
    puts "flipper :chat_backfill_running: #{Flipper.enabled?(:chat_backfill_running)}"
  end
end
