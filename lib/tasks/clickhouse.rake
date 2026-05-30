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

  # TASK-251.14c → TASK-251.58: seeds the T0 watermark in Redis. The actual backfill loop runs in
  # Clickhouse::ChatBackfillCycleWorker (Sidekiq cron, every minute). Cron survives Kamal container
  # swaps natively — the previous detached-rake pattern (where this task held its own blocking loop)
  # died 4× during the TASK-251.14 chat backfill window 2026-05-29 and required manual operator
  # re-spawn. The blocking loop has been removed (CR iter4 M1: the lock-vs-loop-runtime mismatch
  # invited the same concurrent-tick race iter3 was supposed to fix).
  #
  # ⚠️ Pick T0 with a safety margin past the IRC queue drain (≈ enable_time + 2× drain cadence,
  # ≥ 2–3 min in practice). Setting T0 = enable_time exactly leaves a small window where messages
  # with tmi-sent-ts < enable_time were still queued in Redis at enable, get mirrored to CH AFTER
  # enable, AND match `timestamp < T0` here → duplicates (the raw table is MergeTree, no engine-
  # level dedup). PR-1d gates on a duplicate-twitch_msg_id spot-check before flipping reads.
  desc "Seed T0 watermark for CH chat backfill (cron-driven via ChatBackfillCycleWorker). See app/services/clickhouse/chat_backfill.rb for T0 safety-margin guidance"
  task :backfill_chat, %i[t0_iso _legacy_batch_size _legacy_sleep_seconds] => :environment do |_, args|
    if args.t0_iso.blank?
      abort "Usage: rake 'clickhouse:backfill_chat[T0_ISO]' " \
            "(e.g. clickhouse:backfill_chat[2026-05-28T03:31:10Z] — enable_time + ~2min). " \
            "BATCH_SIZE/SLEEP_S positional args are accepted for backward-compat but ignored " \
            "(cron worker uses Clickhouse::ChatBackfill::DEFAULT_{BATCH_SIZE,SLEEP_SECONDS} constants — " \
            "edit those in code to tune)"
    end

    begin
      t0 = Time.parse(args.t0_iso)
    rescue ArgumentError
      abort "✗ T0 must be ISO8601 (e.g. 2026-05-28T03:29:10Z), got: #{args.t0_iso}"
    end
    abort "✗ T0 (#{t0.iso8601}) is in the future — backfill watermark must be the dual-write enable time, in the past" if t0 > Time.current

    unless Flipper.enabled?(:chat_backfill_running)
      abort "✗ Flipper :chat_backfill_running is OFF — enable it before seeding T0 " \
            "(`Flipper.enable(:chat_backfill_running)` is the kill-switch; flip OFF anytime to pause)"
    end

    result = Clickhouse::ChatBackfill.call(t0: t0)
    puts "ChatBackfill: status=#{result.status} rows_so_far=#{result.rows_processed}"
    puts "Cron-driven Clickhouse::ChatBackfillCycleWorker will resume on the next minute tick (≤60s)."
    puts "Monitor progress: `rake clickhouse:backfill_chat_status` (read-only Redis dump) or tail Sidekiq logs."
    abort "✗ T0 seed unexpected status=#{result.status}" unless result.status == "seeded"
  end

  # NB: status="running" can be stale if a previous run was SIGKILLed (no chance to write the final
  # status); cross-check with the live process / Flipper kill-switch state before assuming an active
  # backfill is in flight. Re-running the rake task is always safe (cursor-resumable).
  desc "Show ClickHouse chat-backfill progress (Redis state — read-only)"
  task backfill_chat_status: :environment do
    redis = Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/1"))
    prefix = Clickhouse::ChatBackfill::REDIS_PREFIX
    puts "t0:             #{redis.get("#{prefix}:t0") || '(unset)'}"
    puts "cursor_id:      #{redis.get("#{prefix}:cursor_id") || '(unset — will start at NULL_UUID)'}"
    puts "rows_processed: #{redis.get("#{prefix}:rows_processed") || '0'}"
    puts "status:         #{redis.get("#{prefix}:status") || '(never run)'} (may be stale if a prior run was SIGKILLed)"
    last_error = redis.get("#{prefix}:last_error")
    puts "last_error:     #{last_error}" if last_error
    puts "flipper :chat_backfill_running: #{Flipper.enabled?(:chat_backfill_running)}"
  end
end
