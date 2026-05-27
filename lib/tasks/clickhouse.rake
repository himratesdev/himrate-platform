# frozen_string_literal: true

# TASK-251.14 (PR 1a): ClickHouse schema provisioning.
#
# Applies every db/clickhouse/*.sql file in sorted (numbered) order. Each file is idempotent
# (CREATE ... IF NOT EXISTS), so `clickhouse:setup` is safe to re-run on every deploy / CI run —
# the same "run from scratch, converge to current schema" model as Rails migrations, but ClickHouse
# has no migration framework so we own this thin applier. The CH database itself is created by the
# accessory (CLICKHOUSE_DB env, config/deploy.yml) / the CI service container; this task manages only
# the tables & views inside it.
namespace :clickhouse do
  SCHEMA_DIR = Rails.root.join("db/clickhouse")

  desc "Create/upgrade ClickHouse tables & views (idempotent; applies db/clickhouse/*.sql in order)"
  task setup: :environment do
    client = Clickhouse.client
    files = Dir[SCHEMA_DIR.join("*.sql")].sort
    abort "✗ No ClickHouse schema files in #{SCHEMA_DIR}" if files.empty?

    files.each do |path|
      statements = sql_statements(File.read(path))
      statements.each do |stmt|
        client.execute(stmt)
      rescue Clickhouse::Error => e
        abort "✗ #{File.basename(path)}: #{e.message}"
      end
      puts "✓ applied #{File.basename(path)} (#{statements.size} statement(s))"
    end
    puts "ClickHouse schema setup complete on #{client.database} @ #{client.host}:#{client.port}"
  end

  desc "Ping ClickHouse (SELECT 1) — exits non-zero if unreachable"
  task ping: :environment do
    c = Clickhouse.client
    abort "✗ ClickHouse NOT reachable @ #{c.host}:#{c.port}" unless c.ping

    puts "✓ ClickHouse reachable @ #{c.host}:#{c.port}/#{c.database}"
  end

  # Split a .sql file into executable statements on `;` line-endings, dropping comment-only / blank
  # fragments (e.g. a trailing comment block after the final statement). Inline `--` comments inside
  # a statement are kept — ClickHouse accepts them.
  def sql_statements(raw)
    raw.split(/;\s*$/m).filter_map do |fragment|
      code_only = fragment.gsub(/^\s*--.*$/, "").strip
      fragment.strip unless code_only.empty?
    end
  end
end
