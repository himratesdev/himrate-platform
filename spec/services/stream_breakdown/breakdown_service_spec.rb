# frozen_string_literal: true

require "rails_helper"

RSpec.describe StreamBreakdown::BreakdownService do
  let(:channel) { create(:channel) }
  let(:stream) do
    create(:stream, channel: channel, started_at: 2.hours.ago, ended_at: nil, game_name: "Just Chatting")
  end

  describe "#call with real snapshots" do
    let(:t0) { stream.started_at.change(sec: 0) }

    before do
      create(:ccv_snapshot, stream: stream, timestamp: t0, ccv_count: 1000, real_viewers_estimate: 900)
      create(:ccv_snapshot, stream: stream, timestamp: t0 + 1.minute, ccv_count: 5000, real_viewers_estimate: 1500)
      create(:chatters_snapshot, stream: stream, timestamp: t0,
        unique_chatters_count: 100, chatters_present_total: 800)
      create(:trust_index_history, channel: channel, stream: stream,
        trust_index_score: 30.0, erv_percent: 30.0, ccv: 5000,
        classification: "needs_review", cold_start_status: "full", calculated_at: t0 + 1.minute)
      Anomaly.create!(stream: stream, timestamp: t0 + 1.minute, anomaly_type: "ccv_step_function",
        confidence: 0.9, details: { "signal_value" => 3.0 })
    end

    subject(:result) { described_class.new(stream: stream, channel: channel).call }

    it "builds a per-minute timeline with real/fake split + anomaly flag" do
      expect(result[:timeline].size).to eq(2)
      spike = result[:timeline].last
      expect(spike[:ccv]).to eq(5000)
      expect(spike[:real]).to eq(1500)
      expect(spike[:fake]).to eq(3500) # 5000 − 1500 manufactured
      expect(spike[:anomaly]).to be(true)
    end

    it "builds the chat funnel from high-water marks (norm nil until INC-2)" do
      expect(result[:funnel]).to include(online: 5000, logged_in: 800, writing: 100, norm_writing_per_1000: nil)
    end

    it "builds the auth-ratio series (logged-in / ccv per minute)" do
      expect(result[:auth_series].first).to include(ratio: 0.8) # 800 / 1000
    end

    it "presents the stream's anomaly events (stream-scoped presenter)" do
      expect(result[:anomalies].map { |a| a[:type] }).to include("ccv_spike")
    end

    it "emits this stream's own TI verdict" do
      expect(result[:verdict]).to include(ti_score: 30.0, erv_percent: 30.0, classification: "needs_review")
    end
  end

  describe "#call with no data (honest empty, no fabrication)" do
    subject(:result) { described_class.new(stream: stream, channel: channel).call }

    it "returns empty series + nil verdict, never invented values" do
      expect(result[:timeline]).to eq([])
      expect(result[:auth_series]).to eq([])
      expect(result[:funnel]).to include(online: nil, logged_in: nil, writing: nil)
      expect(result[:verdict]).to be_nil
    end
  end
end
