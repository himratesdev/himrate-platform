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

    # Stub Telegram
    stub_request(:post, /api.telegram.org/).to_return(status: 200, body: '{"ok":true}')
  end

  describe ".check" do
    context "when divergence > 20" do
      it "sends Telegram alert" do
        # Part 1 TI = 50.0, Final TI = 75.0 → divergence = 25
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("test-token")
        allow(ENV).to receive(:[]).with("TELEGRAM_ALERT_CHAT_ID").and_return("12345")

        described_class.check(stream)

        expect(WebMock).to have_requested(:post, "https://api.telegram.org/bottest-token/sendMessage")
      end
    end

    context "when divergence <= 20" do
      before do
        stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "ti_score" => 70.0 } ])
      end

      it "does not send alert" do
        # Part 1 TI = 70.0, Final TI = 75.0 → divergence = 5
        described_class.check(stream)

        expect(WebMock).not_to have_requested(:post, /api.telegram.org/)
      end
    end

    context "when not merged" do
      before { stream.update!(merged_parts_count: 1) }

      it "skips" do
        described_class.check(stream)
        expect(WebMock).not_to have_requested(:post, /api.telegram.org/)
      end
    end

    context "when TELEGRAM_BOT_TOKEN not set" do
      it "skips without error" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return(nil)

        expect { described_class.check(stream) }.not_to raise_error
      end
    end

    context "with nil ti_score in boundary" do
      before do
        stream.update!(part_boundaries: [ { "ended_at" => 3.hours.ago.iso8601, "ti_score" => nil } ])
      end

      it "skips that pair" do
        described_class.check(stream)
        expect(WebMock).not_to have_requested(:post, /api.telegram.org/)
      end
    end
  end
end
