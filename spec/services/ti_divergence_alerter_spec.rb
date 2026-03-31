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
end
