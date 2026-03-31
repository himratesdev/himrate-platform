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
    allow(HealthScoreRefreshWorker).to receive(:perform_async)
    allow(StreamerRatingRefreshWorker).to receive(:perform_async)
    allow(StreamExpiringWorker).to receive(:perform_at)
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

    it "broadcasts stream_ended notification" do
      described_class.new.perform(stream.id)

      expect(PostStreamNotificationService).to have_received(:broadcast_stream_ended)
        .with(stream, instance_of(PostStreamReport))
    end

    it "triggers HealthScore and Rating refresh" do
      described_class.new.perform(stream.id)

      expect(HealthScoreRefreshWorker).to have_received(:perform_async).with(channel.id)
      expect(StreamerRatingRefreshWorker).to have_received(:perform_async).with(channel.id)
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
end
