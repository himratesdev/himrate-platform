# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::PenaltyEventEmitter do
  let(:channel) { create(:channel) }
  let(:stream) do
    create(:stream, channel: channel,
      started_at: 1.hour.ago, ended_at: 10.minutes.ago)
  end

  describe ".call" do
    it "does nothing when TI nil" do
      expect {
        described_class.call(channel: channel, stream: stream, ti_score: nil)
      }.not_to change(RehabilitationPenaltyEvent, :count)
    end

    it "emits penalty event when TI < 50 and no active event" do
      expect {
        described_class.call(channel: channel, stream: stream, ti_score: 35)
      }.to change(RehabilitationPenaltyEvent, :count).by(1)

      event = RehabilitationPenaltyEvent.last
      expect(event.channel_id).to eq(channel.id)
      expect(event.applied_stream_id).to eq(stream.id)
      expect(event.initial_penalty).to eq(15.0) # 50 - 35
      expect(event.resolved_at).to be_nil
    end

    it "does not emit second event while first is active" do
      RehabilitationPenaltyEvent.create!(
        channel: channel, initial_penalty: 20, applied_at: 1.day.ago
      )

      expect {
        described_class.call(channel: channel, stream: stream, ti_score: 30)
      }.not_to change(RehabilitationPenaltyEvent, :count)
    end

    it "does not emit when TI >= 50" do
      expect {
        described_class.call(channel: channel, stream: stream, ti_score: 70)
      }.not_to change(RehabilitationPenaltyEvent, :count)
    end

    it "resolves active event when clean streams threshold reached" do
      applied_time = 30.days.ago
      event = RehabilitationPenaltyEvent.create!(
        channel: channel, initial_penalty: 20,
        applied_at: applied_time, required_clean_streams: 3
      )

      # Create 3 clean streams after penalty applied_at
      3.times do |i|
        s = create(:stream, channel: channel,
          started_at: applied_time + (i + 1).days,
          ended_at: applied_time + (i + 1).days + 1.hour)
        create(:trust_index_history, channel: channel, stream: s,
          trust_index_score: 60, erv_percent: 60, ccv: 100, confidence: 0.85,
          classification: "needs_review", cold_start_status: "full",
          signal_breakdown: {}, calculated_at: applied_time + (i + 1).days + 1.hour)
      end

      described_class.call(channel: channel, stream: stream, ti_score: 65)

      event.reload
      expect(event.resolved_at).to be_present
      expect(event.clean_streams_at_resolve).to eq(3)
    end

    it "ignores pre-penalty TI refreshes in clean stream count (M6 fix)" do
      applied_time = 10.days.ago
      event = RehabilitationPenaltyEvent.create!(
        channel: channel, initial_penalty: 20,
        applied_at: applied_time, required_clean_streams: 2
      )

      # PRE-penalty stream (started before applied_at)
      pre = create(:stream, channel: channel,
        started_at: 20.days.ago, ended_at: 19.days.ago)
      # TI recomputed AFTER penalty applied, but for PRE-penalty stream
      create(:trust_index_history, channel: channel, stream: pre,
        trust_index_score: 80, erv_percent: 80, ccv: 100, confidence: 0.85,
        classification: "trusted", cold_start_status: "full",
        signal_breakdown: {}, calculated_at: 1.hour.ago)

      described_class.call(channel: channel, stream: stream, ti_score: 70)

      event.reload
      expect(event.resolved_at).to be_nil # pre-penalty stream should NOT count
    end
  end
end
