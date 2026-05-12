# frozen_string_literal: true

require "rails_helper"
require "rake"

# TASK-086 FR-039/041/048: cleanup rake tasks.
RSpec.describe "cleanup rake tasks" do
  before(:all) { Rails.application.load_tasks if Rake::Task.tasks.empty? }
  before do
    Rake::Task.tasks.each(&:reenable)
    CleanupRetentionConfigSeeder.seed!
  end

  let(:channel) { create(:channel) }
  let(:ended_old) { create(:stream, channel: channel, started_at: 100.days.ago, ended_at: 95.days.ago) }
  let(:live) { create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil) }

  describe "cleanup:initial_backfill" do
    it "aborts on an invalid table arg" do
      expect { Rake::Task["cleanup:initial_backfill"].invoke("not_a_table") }.to raise_error(SystemExit)
    end

    it "dry-run is the safe default — prints a preview and deletes nothing (TC-010)" do
      intermediate = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 96.days.ago)
      _final = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 95.days.ago)

      expect { Rake::Task["cleanup:initial_backfill"].invoke("tih") }.to output(/DRY-RUN/).to_stdout
      expect(TrustIndexHistory.exists?(intermediate.id)).to be true
    end

    it "actual run deletes intermediate TIH, preserves the final and live TIH (TC-011)" do
      intermediate = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 96.days.ago)
      final = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 95.days.ago)
      live_tih = create(:trust_index_history, channel: channel, stream: live, calculated_at: 2.minutes.ago)

      expect { Rake::Task["cleanup:initial_backfill"].invoke("tih", "false") }.to output(/Done: 1 intermediate/).to_stdout
      expect(TrustIndexHistory.exists?(intermediate.id)).to be false
      expect(TrustIndexHistory.exists?(final.id)).to be true
      expect(TrustIndexHistory.exists?(live_tih.id)).to be true
    end

    it "actual run deletes old rows for a non-TIH table" do
      old = CcvSnapshot.create!(stream: ended_old, ccv_count: 1, timestamp: 95.days.ago)
      recent = CcvSnapshot.create!(stream: ended_old, ccv_count: 2, timestamp: 1.day.ago)

      expect { Rake::Task["cleanup:initial_backfill"].invoke("ccv_snapshots", "false") }.to output(/Done: 1 ccv_snapshots/).to_stdout
      expect(CcvSnapshot.exists?(old.id)).to be false
      expect(CcvSnapshot.exists?(recent.id)).to be true
    end
  end

  describe "cleanup:report" do
    it "prints a per-table summary from cleanup_audit_logs" do
      CleanupAuditLog.create!(table_name: "tih", run_at: 1.hour.ago, status: :success, deleted_count: 7, duration_ms: 120)
      CleanupAuditLog.create!(table_name: "tih", run_at: 30.minutes.ago, status: :error, deleted_count: 0, duration_ms: 5)

      expect { Rake::Task["cleanup:report"].invoke("tih") }.to output(/tih: runs=2 deleted=7/).to_stdout
    end

    it "handles no rows gracefully" do
      expect { Rake::Task["cleanup:report"].invoke("nope") }.to output(/no rows/).to_stdout
    end
  end

  describe "cleanup:restore_from_archive" do
    it "aborts with an explanatory message (cold-archive pipeline is a follow-up)" do
      expect { Rake::Task["cleanup:restore_from_archive"].invoke("tih", channel.id) }.to raise_error(SystemExit)
    end
  end
end
