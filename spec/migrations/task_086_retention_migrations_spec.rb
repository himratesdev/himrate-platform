# frozen_string_literal: true

require "rails_helper"

# TASK-086 §5.3 migration verification (FR-006/018/031/032/036).
RSpec.describe "TASK-086 retention migrations", type: :model do
  let(:conn) { ActiveRecord::Base.connection }

  describe "seed_cleanup_retention_thresholds (FR-006/019..022)" do
    # Test env loads structure.sql without data; re-apply the seed (same content as the
    # migration, idempotent — on_duplicate: :skip) and verify the rows it produces.
    before { CleanupRetentionConfigSeeder.seed! }

    it "seeds retention_days for trust_index_histories and the 4 cleanup tables" do
      expect(SignalConfiguration.value_for("trust_index_histories", "default", "retention_days")).to eq(90)
      %w[ti_signals ccv_snapshots chatters_snapshots chat_messages].each do |table|
        expect(SignalConfiguration.value_for("cleanup", table, "retention_days")).to eq(90)
      end
    end

    it "does NOT seed a retention row for cleanup_audit_logs (indefinite retention)" do
      expect(
        SignalConfiguration.exists?(signal_type: "cleanup", category: "cleanup_audit_logs", param_name: "retention_days")
      ).to be false
    end

    it "is idempotent — re-running does not duplicate or overwrite admin-tuned values" do
      SignalConfiguration.where(signal_type: "trust_index_histories", category: "default", param_name: "retention_days").update_all(param_value: 120)
      CleanupRetentionConfigSeeder.seed!
      expect(SignalConfiguration.where(signal_type: "trust_index_histories", category: "default", param_name: "retention_days").count).to eq(1)
      expect(SignalConfiguration.value_for("trust_index_histories", "default", "retention_days")).to eq(120)
    end
  end

  describe "streams.ended_at partial index (FR-018)" do
    it "exists as a partial index WHERE ended_at IS NOT NULL" do
      idx = conn.indexes(:streams).find { |i| i.name == "idx_streams_ended_at_partial" }
      expect(idx).to be_present
      expect(idx.where).to include("ended_at IS NOT NULL")
    end

    it "is a valid index the cleanup query can EXPLAIN against" do
      plan = conn.execute(
        "EXPLAIN SELECT s.id FROM streams s WHERE s.ended_at IS NOT NULL AND s.ended_at < now() - interval '90 days'"
      ).map { |r| r["QUERY PLAN"] }.join("\n")
      # On an empty test table the planner may still seq-scan; the cost-based choice on a
      # populated table is verified in QA on staging. Here: assert the index is present + valid.
      expect(plan).to be_a(String)
      expect(conn.indexes(:streams).map(&:name)).to include("idx_streams_ended_at_partial")
    end
  end

  describe "cleanup_audit_logs table (FR-031/034/035/036)" do
    it "has the final schema columns with bigint duration_ms and no error_message" do
      cols = conn.columns(:cleanup_audit_logs).index_by(&:name)
      expect(cols.keys).to include("run_at", "table_name", "status", "deleted_count", "archived_count",
                                   "duration_ms", "error_code", "error_context", "retention_days")
      expect(cols.keys).not_to include("error_message")
      expect(cols["duration_ms"].sql_type).to eq("bigint")
      expect(cols["error_context"].sql_type).to eq("jsonb")
      expect(cols["id"].sql_type).to eq("uuid")
    end

    it "has the errors partial index (status, run_at DESC) WHERE status != 0" do
      idx = conn.indexes(:cleanup_audit_logs).find { |i| i.name == "idx_cleanup_audit_logs_errors" }
      expect(idx).to be_present
      expect(idx.where).to include("status <> 0").or include("status != 0")
    end
  end

  describe "latest_tih_per_stream materialized view (FR-032)" do
    def mv_columns
      conn.select_values("SELECT attname FROM pg_attribute WHERE attrelid = 'latest_tih_per_stream'::regclass AND attnum > 0 AND NOT attisdropped")
    end

    it "exists and has a UNIQUE index on stream_id (required for REFRESH CONCURRENTLY)" do
      exists = conn.select_value("SELECT 1 FROM pg_matviews WHERE matviewname = 'latest_tih_per_stream'")
      expect(exists).to eq(1)
      unique_idx = conn.select_value(
        "SELECT 1 FROM pg_indexes WHERE tablename = 'latest_tih_per_stream' AND indexdef ILIKE '%UNIQUE%(stream_id)%'"
      )
      expect(unique_idx).to eq(1)
    end

    it "uses the ACTUAL TIH column names (trust_index_score / erv_percent / signal_breakdown)" do
      expect(mv_columns).to include("trust_index_score", "erv_percent", "signal_breakdown", "ccv")
      expect(mv_columns).not_to include("ti_score", "erv", "signals_data")
    end

    # NB: REFRESH ... CONCURRENTLY cannot run inside a transaction (and specs use
    # transactional fixtures). The unique index above is what makes CONCURRENTLY legal
    # in production; here we verify a plain REFRESH populates the per-stream final TIH.
    it "REFRESH MATERIALIZED VIEW populates one row per ended stream with its final TIH (TC-036)" do
      channel = create(:channel)
      ended = create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: 1.hour.ago)
      create(:trust_index_history, channel: channel, stream: ended, calculated_at: 50.minutes.ago, trust_index_score: 40)
      create(:trust_index_history, channel: channel, stream: ended, calculated_at: 30.minutes.ago, trust_index_score: 77)
      create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil) # live → excluded

      conn.execute("REFRESH MATERIALIZED VIEW latest_tih_per_stream")
      rows = conn.select_all("SELECT stream_id, trust_index_score FROM latest_tih_per_stream").to_a

      expect(rows.size).to eq(1)
      expect(rows.first["stream_id"]).to eq(ended.id)
      expect(rows.first["trust_index_score"].to_f).to eq(77.0)
    end
  end
end
