# frozen_string_literal: true

require "rails_helper"

RSpec.describe TiDivergenceAlerter do
  let(:channel) { create(:channel) }
  let(:stream) do
    create(:stream, channel: channel, started_at: 5.hours.ago, ended_at: 1.hour.ago,
      merged_parts_count: 2,
      part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "ti_score" => 50.0, "erv_percent" => 50.0, "part_number" => 1 } ])
  end

  before do
    create(:trust_index_history,
      channel: channel, stream: stream,
      trust_index_score: 75.0, erv_percent: 75.0, ccv: 5000,
      confidence: 0.85, classification: "needs_review", cold_start_status: "full",
      signal_breakdown: {}, calculated_at: 30.minutes.ago)

    allow(TelegramAlertWorker).to receive(:perform_async)

    # ti_v2_engine is in ALL_FLAGS → rails_helper enables it for every example. The seed above is
    # a v1 row (trust_index_score / boundary "ti_score"), so the legacy stance is stated explicitly.
    # The production axis (authenticity) is covered by "under ti_v2_engine" at the bottom.
    allow(Flipper).to receive(:enabled?).and_call_original
    allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(false)
  end

  describe ".check" do
    context "when divergence > 20" do
      it "enqueues TelegramAlertWorker" do
        # Part 1 TI = 50.0, Final TI = 75.0 → divergence = 25
        described_class.check(stream)

        expect(TelegramAlertWorker).to have_received(:perform_async)
          .with(a_string_including("TI Divergence Alert"))
      end

      it "includes channel login and divergence in message" do
        described_class.check(stream)

        expect(TelegramAlertWorker).to have_received(:perform_async)
          .with(a_string_including(channel.login).and(including("25.0 points")))
      end
    end

    context "when divergence <= 20" do
      before do
        stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "ti_score" => 70.0 } ])
      end

      it "does not enqueue alert" do
        # Part 1 TI = 70.0, Final TI = 75.0 → divergence = 5
        described_class.check(stream)

        expect(TelegramAlertWorker).not_to have_received(:perform_async)
      end
    end

    context "when not merged" do
      before { stream.update!(merged_parts_count: 1) }

      it "skips" do
        described_class.check(stream)
        expect(TelegramAlertWorker).not_to have_received(:perform_async)
      end
    end

    context "with nil ti_score in boundary" do
      before do
        stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "ti_score" => nil } ])
      end

      it "skips that pair" do
        described_class.check(stream)
        expect(TelegramAlertWorker).not_to have_received(:perform_async)
      end
    end

    context "with multiple parts and divergence only in one pair" do
      before do
        stream.update!(
          merged_parts_count: 3,
          part_boundaries: [
            { "ended_at" => 4.hours.ago.iso8601, "ti_score" => 72.0, "part_number" => 1 },
            { "ended_at" => 2.hours.ago.iso8601, "ti_score" => 45.0, "part_number" => 2 }
          ]
        )
        # Final TI = 75.0. Pair 1→2: |45-72|=27 > 20. Pair 2→3: |75-45|=30 > 20.
      end

      it "enqueues alert for each divergent pair" do
        described_class.check(stream)

        expect(TelegramAlertWorker).to have_received(:perform_async).twice
      end
    end
  end
  # PR3b (T1-074, M13b): under the cutover engine the divergence axis is `authenticity`
  # (same 0-100 scale, so DIVERGENCE_THRESHOLD=20 keeps its meaning).
  describe ".check under ti_v2_engine" do
    before do
      allow(Flipper).to receive(:enabled?).with(:ti_v2_engine).and_return(true)
      TrustIndexHistory.where(stream_id: stream.id).delete_all
      TrustIndexHistory.create!(channel: channel, stream: stream, engine_version: "v2",
                                authenticity: 75.0, cold_start_tier: "full", calculated_at: 30.minutes.ago)
    end

    it "alerts on an authenticity divergence > 20" do
      stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "authenticity" => 50.0, "part_number" => 1 } ])
      described_class.check(stream)
      expect(TelegramAlertWorker).to have_received(:perform_async)
        .with(a_string_including("25.0 points"))
    end

    it "falls back to the pre-cutover ti_score on boundaries written before the flip" do
      # Merged streams spanning the cutover keep boundaries that only carry "ti_score" — without
      # the fallback those parts would silently drop out of divergence detection.
      stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "ti_score" => 50.0, "part_number" => 1 } ])
      described_class.check(stream)
      expect(TelegramAlertWorker).to have_received(:perform_async)
        .with(a_string_including("TI Divergence Alert"))
    end

    it "ignores v1 rows for the final value (no cross-engine mixing)" do
      TrustIndexHistory.where(stream_id: stream.id).delete_all
      create(:trust_index_history, channel: channel, stream: stream, trust_index_score: 75.0,
                                   cold_start_status: "full", calculated_at: 30.minutes.ago)
      stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "authenticity" => 50.0, "part_number" => 1 } ])
      described_class.check(stream)
      expect(TelegramAlertWorker).not_to have_received(:perform_async)
    end
  end
end
