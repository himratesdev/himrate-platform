# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clickhouse::Schema do
  describe ".statements" do
    it "returns a single statement and drops a trailing comment block" do
      raw = <<~SQL
        -- a leading comment
        CREATE TABLE t (a UInt8) ENGINE = Memory;
        -- trailing notes, not a statement
        -- more notes
      SQL

      statements = described_class.statements(raw)
      expect(statements.size).to eq(1)
      expect(statements.first).to start_with("-- a leading comment\nCREATE TABLE t")
    end

    it "splits multiple statements on `;` line-endings" do
      raw = "CREATE TABLE a (x UInt8) ENGINE = Memory;\nCREATE TABLE b (y UInt8) ENGINE = Memory;\n"
      statements = described_class.statements(raw)
      expect(statements.size).to eq(2)
      expect(statements[0]).to include("CREATE TABLE a")
      expect(statements[1]).to include("CREATE TABLE b")
    end

    it "keeps inline `--` comments inside a statement (ClickHouse accepts them)" do
      raw = "CREATE TABLE t\n(\n  a UInt8 -- the column\n)\nENGINE = Memory;\n"
      statements = described_class.statements(raw)
      expect(statements.size).to eq(1)
      expect(statements.first).to include("-- the column")
    end

    it "returns [] for a comment-only / blank file" do
      expect(described_class.statements("-- only a comment\n\n")).to eq([])
      expect(described_class.statements("")).to eq([])
    end
  end

  describe ".files" do
    it "lists db/clickhouse/*.sql in numeric order and includes the committed chat_messages DDL" do
      files = described_class.files
      expect(files).to all(end_with(".sql"))
      expect(files).to eq(files.sort)
      expect(files.map { |f| File.basename(f) }).to include("001_chat_messages.sql")
    end

    # Phase 6 M (2026-06-03): the bloom_filter skipping index on chat_messages.stream_id is
    # provisioned in two complementary places. Fresh environments (CI, new prod) pick it up via
    # the CREATE TABLE clause in 001; existing CH instances need the standalone ALTER+MATERIALIZE
    # in 003. We assert BOTH live in the manifest so a future refactor can't silently drop one.
    it "ships the bloom_filter skipping index in both 001 (CREATE TABLE) and 003 (ALTER backfill)" do
      basenames = described_class.files.map { |f| File.basename(f) }
      expect(basenames).to include("003_add_stream_id_index_to_chat_messages.sql")

      create_table_sql = File.read(Clickhouse::Schema::DIR.join("001_chat_messages.sql"))
      expect(create_table_sql).to match(/INDEX\s+idx_stream_id\s+stream_id\s+TYPE\s+bloom_filter\s+GRANULARITY\s+4/i)

      backfill_sql = File.read(Clickhouse::Schema::DIR.join("003_add_stream_id_index_to_chat_messages.sql"))
      expect(backfill_sql).to match(/ALTER TABLE chat_messages\s+ADD INDEX IF NOT EXISTS idx_stream_id/i)
      expect(backfill_sql).to match(/MATERIALIZE INDEX idx_stream_id/i)

      # Two executable statements (ADD + MATERIALIZE) — the splitter must surface both so the
      # rake task applies the materialization, not just the registration. Without MATERIALIZE,
      # existing partitions stay unindexed → no perf win until a part is organically rewritten.
      statements = described_class.statements(backfill_sql)
      expect(statements.size).to eq(2)
      expect(statements[0]).to match(/ADD INDEX/i)
      expect(statements[1]).to match(/MATERIALIZE INDEX/i)
    end
  end
end
