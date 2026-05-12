# frozen_string_literal: true

require "rails_helper"

RSpec.describe CleanupWorker, type: :worker do
  describe "sidekiq options" do
    it "uses monitoring queue" do
      expect(described_class.get_sidekiq_options["queue"].to_s).to eq("monitoring")
    end

    it "retries 3 times" do
      expect(described_class.get_sidekiq_options["retry"]).to eq(3)
    end
  end

  describe "#perform" do
    let(:channel) { create(:channel) }
    let(:stream) { create(:stream, channel: channel) }

    # Test env loads structure.sql without data — seed the retention config rows
    # the worker reads (mirrors 20260512100001_seed_cleanup_retention_thresholds).
    # Prometheus push is stubbed (no pushgateway in test) — same pattern as accessory specs.
    before do
      CleanupRetentionConfigSeeder.seed!
      allow(PrometheusMetrics).to receive(:observe_cleanup_run)
      allow(PrometheusMetrics).to receive(:observe_cleanup_table_rows)
      allow(PrometheusMetrics).to receive(:observe_cleanup_audit_insert_failure)
    end

    # --- pre-existing time-series cleanups (TASK-016/033, migrated to SignalConfiguration) ---

    context "old signals (FR-019)" do
      it "deletes signals older than the configured retention, keeps recent" do
        old_signal = TiSignal.create!(stream: stream, timestamp: 91.days.ago, signal_type: "auth_ratio", value: 0.5)
        recent_signal = TiSignal.create!(stream: stream, timestamp: 1.day.ago, signal_type: "auth_ratio", value: 0.8)

        described_class.new.perform

        expect(TiSignal.exists?(old_signal.id)).to be false
        expect(TiSignal.exists?(recent_signal.id)).to be true
      end

      it "reads retention_days from SignalConfiguration ('cleanup', 'ti_signals', 'retention_days') (TC-020)" do
        SignalConfiguration.where(signal_type: "cleanup", category: "ti_signals", param_name: "retention_days").update_all(param_value: 30)
        ActiveSupport::CurrentAttributes.clear_all
        old_signal = TiSignal.create!(stream: stream, timestamp: 31.days.ago, signal_type: "auth_ratio", value: 0.5)
        kept_signal = TiSignal.create!(stream: stream, timestamp: 29.days.ago, signal_type: "auth_ratio", value: 0.8)

        described_class.new.perform

        expect(TiSignal.exists?(old_signal.id)).to be false
        expect(TiSignal.exists?(kept_signal.id)).to be true
      end
    end

    context "old ccv_snapshots (FR-020, TC-021)" do
      it "deletes ccv_snapshots older than 90 days" do
        old = CcvSnapshot.create!(stream: stream, ccv_count: 1000, timestamp: 91.days.ago)
        recent = CcvSnapshot.create!(stream: stream, ccv_count: 2000, timestamp: 1.day.ago)

        described_class.new.perform

        expect(CcvSnapshot.exists?(old.id)).to be false
        expect(CcvSnapshot.exists?(recent.id)).to be true
      end
    end

    context "old chatters_snapshots (FR-021, TC-022)" do
      it "deletes chatters_snapshots older than 90 days" do
        old = ChattersSnapshot.create!(stream: stream, unique_chatters_count: 100, total_messages_count: 500, timestamp: 91.days.ago)
        recent = ChattersSnapshot.create!(stream: stream, unique_chatters_count: 200, total_messages_count: 1000, timestamp: 1.day.ago)

        described_class.new.perform

        expect(ChattersSnapshot.exists?(old.id)).to be false
        expect(ChattersSnapshot.exists?(recent.id)).to be true
      end
    end

    context "old chat_messages (FR-022, TC-023)" do
      it "deletes chat_messages older than 90 days" do
        old = ChatMessage.create!(stream: stream, channel_login: "test", username: "user1", timestamp: 91.days.ago)
        recent = ChatMessage.create!(stream: stream, channel_login: "test", username: "user2", timestamp: 1.day.ago)

        described_class.new.perform

        expect(ChatMessage.exists?(old.id)).to be false
        expect(ChatMessage.exists?(recent.id)).to be true
      end

      it "still prunes NULL-stream_id chat_messages at the default window when a per-channel override exists (CR Nit-4)" do
        SignalConfiguration.create!(signal_type: "cleanup", category: "channel:#{channel.id}", param_name: "retention_days", param_value: 365)
        ActiveSupport::CurrentAttributes.clear_all
        orphan_old = ChatMessage.create!(stream: nil, channel_login: "ghost", username: "u", timestamp: 120.days.ago)   # > 90d default → deleted
        orphan_recent = ChatMessage.create!(stream: nil, channel_login: "ghost", username: "u2", timestamp: 1.day.ago)  # < 90d → kept
        kept_for_override = ChatMessage.create!(stream: create(:stream, channel: channel), channel_login: "c", username: "u3", timestamp: 200.days.ago) # < 365d → kept

        described_class.new.perform

        expect(ChatMessage.exists?(orphan_old.id)).to be false
        expect(ChatMessage.exists?(orphan_recent.id)).to be true
        expect(ChatMessage.exists?(kept_for_override.id)).to be true
      end
    end

    # --- MIN_RETENTION_DAYS floor applies to ALL 5 time-series tables, not just TIH (PG re-review W3) ---

    context "MIN_RETENTION_DAYS floor on a non-TIH table (ti_signals)" do
      it "clamps a misconfigured ti_signals retention_days=0 to MIN_RETENTION_DAYS — rows inside the 7d floor survive" do
        SignalConfiguration.where(signal_type: "cleanup", category: "ti_signals", param_name: "retention_days").update_all(param_value: 0)
        ActiveSupport::CurrentAttributes.clear_all
        # Without the floor (cutoff ≈ now) this 3-day-old row would be deleted; with the 7d floor it must survive.
        kept_in_floor = TiSignal.create!(stream: stream, timestamp: 3.days.ago, signal_type: "auth_ratio", value: 0.5)
        deleted_past_floor = TiSignal.create!(stream: stream, timestamp: 10.days.ago, signal_type: "auth_ratio", value: 0.6)

        described_class.new.perform

        expect(TiSignal.exists?(kept_in_floor.id)).to be true
        expect(TiSignal.exists?(deleted_past_floor.id)).to be false
      end

      it "records the clamped retention_days (>= MIN_RETENTION_DAYS) in the ti_signals audit row when admin set 0" do
        SignalConfiguration.where(signal_type: "cleanup", category: "ti_signals", param_name: "retention_days").update_all(param_value: 0)
        ActiveSupport::CurrentAttributes.clear_all

        described_class.new.perform

        row = CleanupAuditLog.where(table_name: "ti_signals").order(:run_at).last
        expect(row.retention_days).to eq(CleanupWorker::MIN_RETENTION_DAYS)
      end
    end

    context "MIN_RETENTION_DAYS floor on a non-TIH table (chat_messages, via cleanup_old_records)" do
      it "clamps a misconfigured chat_messages retention_days=0 to MIN_RETENTION_DAYS — rows inside the 7d floor survive" do
        SignalConfiguration.where(signal_type: "cleanup", category: "chat_messages", param_name: "retention_days").update_all(param_value: 0)
        ActiveSupport::CurrentAttributes.clear_all
        kept_in_floor = ChatMessage.create!(stream: stream, channel_login: "c", username: "u", timestamp: 3.days.ago)
        deleted_past_floor = ChatMessage.create!(stream: stream, channel_login: "c", username: "u2", timestamp: 10.days.ago)

        described_class.new.perform

        expect(ChatMessage.exists?(kept_in_floor.id)).to be true
        expect(ChatMessage.exists?(deleted_past_floor.id)).to be false
      end
    end

    context "expired sessions" do
      let(:user) { create(:user) }

      it "deletes expired inactive sessions" do
        expired = Session.create!(user: user, token: SecureRandom.hex(32), expires_at: 1.day.ago, is_active: false)
        active = Session.create!(user: user, token: SecureRandom.hex(32), expires_at: 1.day.from_now, is_active: true)

        described_class.new.perform

        expect(Session.exists?(expired.id)).to be false
        expect(Session.exists?(active.id)).to be true
      end
    end

    context "per-channel retention override for the 4 cleanup tables (FR-025, TC-027/028)" do
      it "honors a channel:<uuid> override (180d) for ccv_snapshots" do
        other_channel = create(:channel)
        other_stream = create(:stream, channel: other_channel)
        SignalConfiguration.create!(signal_type: "cleanup", category: "channel:#{channel.id}", param_name: "retention_days", param_value: 180)
        ActiveSupport::CurrentAttributes.clear_all

        kept_for_overridden = CcvSnapshot.create!(stream: stream, ccv_count: 1, timestamp: 120.days.ago)       # < 180d → kept
        deleted_for_default = CcvSnapshot.create!(stream: other_stream, ccv_count: 1, timestamp: 120.days.ago) # > 90d  → deleted

        described_class.new.perform

        expect(CcvSnapshot.exists?(kept_for_overridden.id)).to be true
        expect(CcvSnapshot.exists?(deleted_for_default.id)).to be false
      end
    end

    # --- TIH retention + conservation (FR-001..004/023, TC-001..004) ---

    context "trust_index_histories retention" do
      let!(:ended_old_stream) { create(:stream, channel: channel, started_at: 100.days.ago, ended_at: 95.days.ago) }
      let!(:live_stream) { create(:stream, channel: channel, started_at: 1.hour.ago, ended_at: nil) }
      let!(:ended_recent_stream) { create(:stream, channel: channel, started_at: 3.days.ago, ended_at: 2.days.ago) }

      def tih_for(target_stream, calculated_at)
        create(:trust_index_history, channel: channel, stream: target_stream, calculated_at: calculated_at)
      end

      it "deletes intermediate TIH of long-ended streams but preserves the final one (TC-001/003)" do
        intermediate_a = tih_for(ended_old_stream, 96.days.ago)
        intermediate_b = tih_for(ended_old_stream, 95.5.days.ago)
        final          = tih_for(ended_old_stream, 95.days.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(intermediate_a.id)).to be false
        expect(TrustIndexHistory.exists?(intermediate_b.id)).to be false
        expect(TrustIndexHistory.exists?(final.id)).to be true
      end

      it "preserves ALL TIH of a live stream (TC-002)" do
        a = tih_for(live_stream, 2.minutes.ago)
        b = tih_for(live_stream, 1.minute.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(a.id)).to be true
        expect(TrustIndexHistory.exists?(b.id)).to be true
      end

      it "preserves intermediate TIH of recently-ended streams (within retention)" do
        a = tih_for(ended_recent_stream, 2.5.days.ago)
        b = tih_for(ended_recent_stream, 2.days.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(a.id)).to be true
        expect(TrustIndexHistory.exists?(b.id)).to be true
      end

      it "preserves a stream with only one TIH row (TC-017)" do
        only = tih_for(ended_old_stream, 96.days.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(only.id)).to be true
      end

      it "tie-breaks identical calculated_at by max id (TC-015)" do
        ts = 96.days.ago
        rows = Array.new(3) { tih_for(ended_old_stream, ts) }
        kept = rows.max_by(&:id)

        described_class.new.perform

        survivors = TrustIndexHistory.where(stream_id: ended_old_stream.id).pluck(:id)
        expect(survivors).to contain_exactly(kept.id)
      end

      it "is idempotent — a second run deletes nothing more (TC-004)" do
        tih_for(ended_old_stream, 96.days.ago)
        final = tih_for(ended_old_stream, 95.days.ago)
        described_class.new.perform
        before = TrustIndexHistory.where(stream_id: ended_old_stream.id).pluck(:id)

        described_class.new.perform

        expect(TrustIndexHistory.where(stream_id: ended_old_stream.id).pluck(:id)).to match_array(before)
        expect(before).to eq([ final.id ])
      end

      it "deletes orphan TIH (stream_id NULL) past the cutoff defensively (TC-013)" do
        orphan_old = create(:trust_index_history, channel: channel, stream: nil, calculated_at: 100.days.ago)
        orphan_recent = create(:trust_index_history, channel: channel, stream: nil, calculated_at: 1.day.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(orphan_old.id)).to be false
        expect(TrustIndexHistory.exists?(orphan_recent.id)).to be true
      end

      it "logs a warning when retention_days < 90 (TC-012)" do
        SignalConfiguration.where(signal_type: "trust_index_histories", category: "default", param_name: "retention_days").update_all(param_value: 7)
        ActiveSupport::CurrentAttributes.clear_all
        allow(Rails.logger).to receive(:warn).and_call_original

        described_class.new.perform

        expect(Rails.logger).to have_received(:warn).with(/retention_days=7 < 90/)
      end

      it "clamps a misconfigured retention_days=0 to MIN_RETENTION_DAYS — the cutoff respects the 7d floor" do
        SignalConfiguration.where(signal_type: "trust_index_histories", category: "default", param_name: "retention_days").update_all(param_value: 0)
        ActiveSupport::CurrentAttributes.clear_all
        # ended_old_stream (ended 95d ago) is well past the 7d floor → its intermediate TIH still go.
        intermediate = tih_for(ended_old_stream, 96.days.ago)
        final        = tih_for(ended_old_stream, 95.days.ago)
        # A stream that ended 3 days ago is INSIDE the clamped 7d window — without the floor it
        # would be eligible (cutoff ≈ now); with the floor its intermediate TIH must survive.
        kept_in_floor_a = tih_for(ended_recent_stream, 2.5.days.ago)
        kept_in_floor_b = tih_for(ended_recent_stream, 2.days.ago)

        described_class.new.perform

        expect(TrustIndexHistory.exists?(intermediate.id)).to be false
        expect(TrustIndexHistory.exists?(final.id)).to be true
        expect(TrustIndexHistory.exists?(kept_in_floor_a.id)).to be true
        expect(TrustIndexHistory.exists?(kept_in_floor_b.id)).to be true
      end

      it "records the clamped retention_days (>= MIN_RETENTION_DAYS) in the tih audit row when admin set 0" do
        SignalConfiguration.where(signal_type: "trust_index_histories", category: "default", param_name: "retention_days").update_all(param_value: 0)
        ActiveSupport::CurrentAttributes.clear_all

        described_class.new.perform

        row = CleanupAuditLog.where(table_name: "tih").order(:run_at).last
        expect(row.retention_days).to eq(CleanupWorker::MIN_RETENTION_DAYS)
      end
    end

    # --- audit log (FR-031) ---

    context "cleanup_audit_logs" do
      it "writes a success row per cleanup sub-run (TC-034)" do
        expect { described_class.new.perform }.to change { CleanupAuditLog.where(status: :success).count }.by(6)
        expect(CleanupAuditLog.where(table_name: "tih", status: :success)).to exist
        expect(CleanupAuditLog.where(table_name: "ti_signals", status: :success)).to exist
      end

      it "records a skipped row for cleanup_audit_logs (indefinite retention — never deleted)" do
        described_class.new.perform
        row = CleanupAuditLog.where(table_name: "cleanup_audit_logs").order(:run_at).last
        expect(row).to be_skipped
        expect(row.retention_days).to be_nil
        expect(CleanupAuditLog.count).to be_positive # not auto-deleted
      end

      it "records an error row (status=error, error_code present, no free-text message) when a sub-run raises" do
        allow(TiSignal).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

        expect { described_class.new.perform }.to raise_error(CleanupWorker::SubRunFailures)
        row = CleanupAuditLog.where(table_name: "ti_signals", status: :error).last
        expect(row).to be_present
        expect(row.error_code).to be_present
        expect(row.attributes.keys).not_to include("error_message")
      end
    end

    # --- per-sub-run rescue-continue (FR-031, CR Should-4) ---

    context "one failed sub-run does not starve the rest" do
      it "still runs the daily TIH cleanup (and the other sub-runs) when an earlier sub-run raises, then re-raises an aggregated error" do
        ended_old = create(:stream, channel: channel, started_at: 100.days.ago, ended_at: 95.days.ago)
        intermediate = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 96.days.ago)
        final = create(:trust_index_history, channel: channel, stream: ended_old, calculated_at: 95.days.ago)
        # Make the FIRST sub-run (:signals — cleanup_old_signals → TiSignal.where) blow up.
        allow(TiSignal).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

        expect { described_class.new.perform }.to raise_error(CleanupWorker::SubRunFailures, /signals/)

        # TIH cleanup (sub-run #6, the pre-launch blocker) still ran:
        expect(TrustIndexHistory.exists?(intermediate.id)).to be false
        expect(TrustIndexHistory.exists?(final.id)).to be true
        # The healthy sub-runs each still wrote a success audit row:
        expect(CleanupAuditLog.where(table_name: "tih", status: :success)).to exist
        expect(CleanupAuditLog.where(table_name: "ccv_snapshots", status: :success)).to exist
        # The failed one wrote an error audit row:
        expect(CleanupAuditLog.where(table_name: "ti_signals", status: :error)).to exist
      end
    end

    # --- consecutive-errors gauge (FR-027, CR Should-3) ---

    context "cleanup_worker_consecutive_errors gauge" do
      it "is pushed with the real consecutive-error count on the error path (including the current run)" do
        # 1 prior error + this run's error = 2 consecutive (below the auto-disable threshold of 3).
        CleanupAuditLog.create!(table_name: "ti_signals", run_at: 2.hours.ago, status: :error, deleted_count: 0)
        allow(TiSignal).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")

        expect { described_class.new.perform }.to raise_error(CleanupWorker::SubRunFailures)

        expect(PrometheusMetrics).to have_received(:observe_cleanup_run)
          .with(hash_including(table: "ti_signals", consecutive_errors: 2))
      end

      it "is 0 for a sub-run that just succeeded" do
        described_class.new.perform

        expect(PrometheusMetrics).to have_received(:observe_cleanup_run)
          .with(hash_including(table: "tih", consecutive_errors: 0))
      end
    end

    # --- partial status (FR-031, CR Should-6) ---

    context "statement_timeout mid-run → status=partial" do
      it "records status=partial with the rows deleted so far when a batched delete is canceled after progress" do
        fake_relation = double("ti_signal_relation")
        deletes = 0
        allow(TiSignal).to receive(:where).and_return(fake_relation)
        allow(fake_relation).to receive(:limit).and_return(fake_relation)
        allow(fake_relation).to receive(:delete_all) do
          deletes += 1
          deletes == 1 ? CleanupWorker::BATCH_SIZE : raise(ActiveRecord::QueryCanceled, "canceling statement due to statement timeout")
        end

        described_class.new.perform # partial is not an error → no SubRunFailures

        row = CleanupAuditLog.where(table_name: "ti_signals").order(:run_at).last
        expect(row).to be_partial
        expect(row.deleted_count).to eq(CleanupWorker::BATCH_SIZE)
        expect(row.error_code).to eq("57014")
      end

      it "records status=error (not partial) when the timeout hits with zero progress" do
        fake_relation = double("ti_signal_relation")
        allow(TiSignal).to receive(:where).and_return(fake_relation)
        allow(fake_relation).to receive(:limit).and_return(fake_relation)
        allow(fake_relation).to receive(:delete_all).and_raise(ActiveRecord::QueryCanceled, "canceling statement due to statement timeout")

        expect { described_class.new.perform }.to raise_error(CleanupWorker::SubRunFailures)

        row = CleanupAuditLog.where(table_name: "ti_signals").order(:run_at).last
        expect(row).to be_error
        expect(row.deleted_count).to eq(0)
      end
    end

    # --- Flipper guard (FR-017) ---

    context "Flipper flag :cleanup_worker" do
      it "is registered as a default-ON flag" do
        expect(FlipperDefaults::ALL_FLAGS).to include(:cleanup_worker)
      end

      it "when disabled: writes a skipped audit row and does no deletes" do
        Flipper.disable(:cleanup_worker)
        old_signal = TiSignal.create!(stream: stream, timestamp: 91.days.ago, signal_type: "auth_ratio", value: 0.5)
        allow(Rails.logger).to receive(:info).and_call_original

        described_class.new.perform

        expect(TiSignal.exists?(old_signal.id)).to be true
        expect(CleanupAuditLog.where(table_name: "cleanup_worker", status: :skipped)).to exist
        expect(Rails.logger).to have_received(:info).with("cleanup_worker: skipped (flag off)")
      end

      it "still pushes the worker heartbeat gauge on a Flipper-skipped run (FR-030 safety-net target)" do
        Flipper.disable(:cleanup_worker)

        described_class.new.perform

        expect(PrometheusMetrics).to have_received(:observe_cleanup_run).with(hash_including(table: "cleanup_worker"))
      end
    end

    # --- advisory lock (FR-033) ---

    context "advisory lock" do
      it "skips (no deletes) when the lock is held by another run" do
        worker = described_class.new
        allow(worker).to receive(:acquire_lock).and_return(false)
        old_signal = TiSignal.create!(stream: stream, timestamp: 91.days.ago, signal_type: "auth_ratio", value: 0.5)
        allow(Rails.logger).to receive(:info).and_call_original

        worker.perform

        expect(TiSignal.exists?(old_signal.id)).to be true
        expect(Rails.logger).to have_received(:info).with("cleanup_worker: another run in progress, skip")
      end
    end

    # --- auto-disable (FR-042) ---

    context "auto-disable after 3 consecutive errors" do
      it "disables :cleanup_worker and fires a critical Alertmanager alert, then re-raises an aggregated error" do
        CleanupAuditLog.create!(table_name: "ti_signals", run_at: 2.hours.ago, status: :error, deleted_count: 0)
        CleanupAuditLog.create!(table_name: "ti_signals", run_at: 1.hour.ago, status: :error, deleted_count: 0)
        allow(TiSignal).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "boom")
        stub_request(:post, "http://himrate-alertmanager:9093/api/v2/alerts").to_return(status: 200)

        expect { described_class.new.perform }.to raise_error(CleanupWorker::SubRunFailures)

        expect(Flipper.enabled?(:cleanup_worker)).to be false
        expect(a_request(:post, "http://himrate-alertmanager:9093/api/v2/alerts")).to have_been_made.at_least_once
      end
    end

    # --- Prometheus gauges (FR-027..029) ---

    context "Prometheus metrics" do
      it "pushes a cleanup_worker gauge for each table after a run + a worker heartbeat" do
        described_class.new.perform

        expect(PrometheusMetrics).to have_received(:observe_cleanup_run).with(hash_including(table: "tih"))
        expect(PrometheusMetrics).to have_received(:observe_cleanup_run).with(hash_including(table: "ti_signals"))
        expect(PrometheusMetrics).to have_received(:observe_cleanup_run).with(hash_including(table: "cleanup_worker"))
      end

      it "pushes per-table row-count gauges on the weekly cadence (FR-029)" do
        stub_const("CleanupWorker::ROW_STATS_WDAY", Date.current.wday) # force the weekly path

        described_class.new.perform

        expect(PrometheusMetrics).to have_received(:observe_cleanup_table_rows)
          .with(hash_including(table: "trust_index_histories", kind: "total"))
        expect(PrometheusMetrics).to have_received(:observe_cleanup_table_rows)
          .with(hash_including(table: "trust_index_histories", kind: "final"))
        expect(PrometheusMetrics).to have_received(:observe_cleanup_table_rows)
          .with(hash_including(table: "ti_signals", kind: "total"))
      end

      it "does NOT push the weekly row-count gauges off the weekly cadence" do
        stub_const("CleanupWorker::ROW_STATS_WDAY", (Date.current.wday + 1) % 7) # never matches today

        described_class.new.perform

        expect(PrometheusMetrics).not_to have_received(:observe_cleanup_table_rows)
      end
    end

    # --- downstream consumers unaffected (TC-006/007/008) ---

    context "downstream consumers after cleanup" do
      it "leaves the per-stream final TIH readable for rating-style DISTINCT ON queries (TC-007/008)" do
        ended = create(:stream, channel: channel, started_at: 100.days.ago, ended_at: 95.days.ago)
        create(:trust_index_history, channel: channel, stream: ended, calculated_at: 96.days.ago, trust_index_score: 40)
        final = create(:trust_index_history, channel: channel, stream: ended, calculated_at: 95.days.ago, trust_index_score: 88)

        described_class.new.perform

        latest = TrustIndexHistory.where(stream_id: ended.id).order(calculated_at: :desc).first
        expect(latest.id).to eq(final.id)
        expect(latest.trust_index_score).to eq(88)
      end
    end
  end
end
