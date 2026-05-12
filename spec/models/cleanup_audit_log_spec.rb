# frozen_string_literal: true

require "rails_helper"

RSpec.describe CleanupAuditLog, type: :model do
  it "has a UUID primary key" do
    row = CleanupAuditLog.create!(table_name: "tih", run_at: Time.current, status: :success, deleted_count: 0)
    expect(row.id).to match(/\A[0-9a-f-]{36}\z/)
  end

  describe "status enum" do
    it "maps success=0 / partial=1 / error=2 / skipped=3" do
      expect(described_class.statuses).to eq("success" => 0, "partial" => 1, "error" => 2, "skipped" => 3)
    end
  end

  describe "validations" do
    it "requires run_at and table_name" do
      row = described_class.new
      expect(row).not_to be_valid
      expect(row.errors.attribute_names).to include(:run_at, :table_name)
    end
  end

  describe ".recent_for_table" do
    it "returns the N most recent rows for a table, newest first" do
      a = described_class.create!(table_name: "tih", run_at: 3.hours.ago, status: :error, deleted_count: 0)
      b = described_class.create!(table_name: "tih", run_at: 2.hours.ago, status: :success, deleted_count: 5)
      _other = described_class.create!(table_name: "ti_signals", run_at: 1.hour.ago, status: :error, deleted_count: 0)

      expect(described_class.recent_for_table("tih", limit: 5).to_a).to eq([ b, a ])
    end
  end

  it "stores error_code + error_context jsonb (no free-text error_message column)" do
    row = described_class.create!(table_name: "tih", run_at: Time.current, status: :error, deleted_count: 0,
                                  error_code: "57014", error_context: { "table" => "tih", "sql_state" => "57014" })
    expect(row.reload.error_context).to eq("table" => "tih", "sql_state" => "57014")
    expect(described_class.column_names).not_to include("error_message")
  end
end
