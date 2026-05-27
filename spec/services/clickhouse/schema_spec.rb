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
  end
end
