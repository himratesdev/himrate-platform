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

  # PR 1e-B (TASK-251.14): `backfill_chat` + `backfill_chat_status` tasks removed alongside
  # `Clickhouse::ChatBackfill` service + `Clickhouse::ChatBackfillCycleWorker` deletion + `chat_messages`
  # PG table drop. The one-shot historical PG→CH backfill ran successfully 2026-05-28..30; any future
  # re-backfill would require a new source (PG no longer has the data) + new service implementation.
end
