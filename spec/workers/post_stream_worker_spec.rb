# frozen_string_literal: true

require "rails_helper"

RSpec.describe PostStreamWorker do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel, started_at: 3.hours.ago, ended_at: 1.hour.ago, peak_ccv: 5000, avg_ccv: 4000, duration_ms: 7_200_000) }

  before do
    create(:trust_index_history,
      channel: channel,
      stream: stream,
      trust_index_score: 72.0,
      erv_percent: 72.0,
      ccv: 5000,
      confidence: 0.85,
      classification: "needs_review",
      cold_start_status: "full",
      signal_breakdown: {},
      calculated_at: 1.minute.ago)

    allow(SignalComputeWorker).to receive(:new).and_return(instance_double(SignalComputeWorker, perform: nil))
    allow(TiDivergenceAlerter).to receive(:check)
    allow(PostStreamNotificationService).to receive(:broadcast_stream_ended)
    allow(StreamerReputationRefreshWorker).to receive(:perform_async)
    allow(StreamExpiringWorker).to receive(:perform_at)
    allow(Trends::LatestTihRefreshWorker).to receive(:perform_in)
    allow(Trends::AggregationWorker).to receive(:perform_async)
  end

  describe "#perform" do
    it "creates post_stream_report with final TI data" do
      expect { described_class.new.perform(stream.id) }
        .to change(PostStreamReport, :count).by(1)

      report = PostStreamReport.last
      expect(report.stream_id).to eq(stream.id)
      expect(report.trust_index_final).to eq(72.0)
      expect(report.erv_percent_final).to eq(72.0)
      expect(report.ccv_peak).to eq(5000)
      expect(report.ccv_avg).to eq(4000)
      expect(report.generated_at).to be_present
    end

    # BUG-TI-SIGNAL-BREAKDOWN regression guard (2026-06-01): build_signals_summary MUST
    # populate from TIH.signal_breakdown JSON column. The `signals` PG table is dead-write
    # post TrustIndex::Engine refactor — old TiSignal.where(...) returned empty {} for every
    # post-stream report. The summary is the canonical per-signal trace stored in
    # PostStreamReport.signals_summary; empty broke the $4.99 stream report endpoint.
    it "populates signals_summary from TIH.signal_breakdown JSON column (not empty signals PG table)" do
      tih = TrustIndexHistory.find_by!(stream: stream)
      tih.update!(signal_breakdown: {
        "auth_ratio" => { "value" => 0.0, "weight" => 0.21, "confidence" => 1.0, "contribution" => 0.0 },
        "chat_behavior" => { "value" => 0.13, "weight" => 0.17, "confidence" => 0.95, "contribution" => 0.0221 }
      })

      described_class.new.perform(stream.id)

      report = PostStreamReport.last
      summary = report.signals_summary
      expect(summary).to be_a(Hash)
      expect(summary.keys).to contain_exactly("auth_ratio", "chat_behavior")
      expect(summary["auth_ratio"]).to include("value" => 0.0, "weight" => 0.21, "confidence" => 1.0)
      expect(summary["chat_behavior"]).to include("value" => 0.13, "weight" => 0.17, "confidence" => 0.95)
    end

    it "broadcasts stream_ended notification" do
      described_class.new.perform(stream.id)

      expect(PostStreamNotificationService).to have_received(:broadcast_stream_ended)
        .with(stream, instance_of(PostStreamReport))
    end

    # TASK-086 FR-032: PostStreamWorker enqueues the MV-refresh worker (2-min delay,
    # NO stream arg — REFRESH ... CONCURRENTLY is a full refresh, advisory-lock dedup
    # in the worker collapses many ended streams into one REFRESH).
    it "schedules Trends::LatestTihRefreshWorker with a 2-minute delay and no stream arg (TC-038)" do
      described_class.new.perform(stream.id)

      expect(Trends::LatestTihRefreshWorker).to have_received(:perform_in).with(2.minutes)
    end

    # TASK-039 FR-018: PostStreamWorker enqueues daily aggregation
    it "enqueues Trends::AggregationWorker для stream's date" do
      described_class.new.perform(stream.id)

      expect(Trends::AggregationWorker).to have_received(:perform_async)
        .with(channel.id, stream.started_at.to_date.iso8601)
    end

    it "schedules stream_expiring worker at ended_at + 17h" do
      described_class.new.perform(stream.id)

      expect(StreamExpiringWorker).to have_received(:perform_at)
        .with(be_within(1.second).of(stream.ended_at + 17.hours), stream.id)
    end

    it "skips TI divergence check for non-merged streams" do
      described_class.new.perform(stream.id)

      expect(TiDivergenceAlerter).not_to have_received(:check)
    end

    it "runs TI divergence check for merged streams" do
      stream.update!(merged_parts_count: 2, part_boundaries: [ { "ended_at" => 2.hours.ago.iso8601, "ti_score" => 50.0 } ])

      described_class.new.perform(stream.id)

      expect(TiDivergenceAlerter).to have_received(:check).with(stream)
    end

    it "upserts report on duplicate execution" do
      described_class.new.perform(stream.id)
      expect(PostStreamReport.count).to eq(1)

      # Second execution — should update, not create
      described_class.new.perform(stream.id)
      expect(PostStreamReport.count).to eq(1)
    end

    it "skips non-existent stream" do
      expect { described_class.new.perform("non-existent-uuid") }.not_to raise_error
    end

    it "creates report with nil TI when no history exists" do
      TrustIndexHistory.where(stream_id: stream.id).delete_all

      described_class.new.perform(stream.id)

      report = PostStreamReport.last
      expect(report.trust_index_final).to be_nil
      expect(report.erv_percent_final).to be_nil
    end
  end

  describe "#detect_silent_skip! (BUG-SIGNAL-COMPUTE-SILENT-SKIP regression guard)" do
    # 2026-06-01: SignalComputeWorker silently short-circuits on flag-off, even for
    # post-stream finalization (PostStreamWorker:94 inline call). Pre-fix, this caused
    # streams with rich data to permanently lose TI compute (PSR.trust_index_final NULL,
    # 0 TIH). Fix: after inline compute, if no TIH exists AND flag is off, schedule a
    # deferred retry + create Anomaly for visibility.

    it "creates compute_failure Anomaly + schedules deferred retry when TIH missing AND flag is OFF" do
      TrustIndexHistory.where(stream_id: stream.id).delete_all
      allow(Flipper).to receive(:enabled?).with(:signal_compute).and_return(false)
      allow(SignalComputeWorker).to receive(:new).and_return(instance_double(SignalComputeWorker, perform: nil))
      allow(SignalComputeWorker).to receive(:perform_in)

      expect {
        described_class.new.perform(stream.id)
      }.to change { Anomaly.where(stream_id: stream.id, anomaly_type: "compute_failure").count }.by(1)

      expect(SignalComputeWorker).to have_received(:perform_in).with(1.hour, stream.id, true)

      anomaly = Anomaly.where(stream_id: stream.id, anomaly_type: "compute_failure").last
      expect(anomaly.details["reason"]).to eq("signal_compute_flag_off_at_finalization")
      expect(anomaly.details["retry_scheduled_at"]).to be_present
    end

    it "does NOT create compute_failure Anomaly when TIH was successfully written (happy path)" do
      # Default state: TIH exists (created in outer `before`)
      allow(SignalComputeWorker).to receive(:new).and_return(instance_double(SignalComputeWorker, perform: nil))
      allow(SignalComputeWorker).to receive(:perform_in)

      expect {
        described_class.new.perform(stream.id)
      }.not_to change { Anomaly.where(stream_id: stream.id, anomaly_type: "compute_failure").count }

      expect(SignalComputeWorker).not_to have_received(:perform_in)
    end

    it "does NOT create compute_failure Anomaly when flag IS enabled but TIH still missing (legitimate empty stream)" do
      # No bots, no chat, no chatters — empty stream legitimately produces no TIH.
      # We don't want to spam Anomaly for every such empty stream.
      TrustIndexHistory.where(stream_id: stream.id).delete_all
      allow(Flipper).to receive(:enabled?).with(:signal_compute).and_return(true)
      allow(SignalComputeWorker).to receive(:new).and_return(instance_double(SignalComputeWorker, perform: nil))
      allow(SignalComputeWorker).to receive(:perform_in)

      expect {
        described_class.new.perform(stream.id)
      }.not_to change { Anomaly.where(stream_id: stream.id, anomaly_type: "compute_failure").count }

      expect(SignalComputeWorker).not_to have_received(:perform_in)
    end
  end
end
