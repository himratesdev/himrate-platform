# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::RehabilitationTracker do
  let(:channel) { create(:channel) }

  describe ".call" do
    it "returns active: false when no penalty events" do
      result = described_class.call(channel)
      expect(result[:active]).to be false
    end

    it "returns progress when active penalty exists" do
      RehabilitationPenaltyEvent.create!(
        channel: channel,
        initial_penalty: 20,
        applied_at: 5.days.ago,
        required_clean_streams: 15
      )

      result = described_class.call(channel)
      expect(result[:active]).to be true
      expect(result[:required]).to eq(15)
      expect(result[:clean_streams]).to eq(0)
      expect(result[:progress_pct]).to eq(0)
    end

    it "counts clean streams since penalty applied_at" do
      applied_time = 10.days.ago
      RehabilitationPenaltyEvent.create!(
        channel: channel,
        initial_penalty: 20,
        applied_at: applied_time,
        required_clean_streams: 15
      )

      # 3 clean streams after penalty
      3.times do |i|
        stream = create(:stream, channel: channel,
          started_at: applied_time + (i + 1).days, ended_at: applied_time + (i + 1).days + 1.hour)
        create(:trust_index_history,
          channel: channel, stream: stream,
          trust_index_score: 70, erv_percent: 70, ccv: 100, confidence: 0.85,
          classification: "needs_review", cold_start_status: "full",
          signal_breakdown: {}, calculated_at: applied_time + (i + 1).days + 1.hour)
      end

      # 1 dirty stream (TI<50) after penalty - shouldn't count
      stream = create(:stream, channel: channel,
        started_at: 2.days.ago, ended_at: 1.day.ago)
      create(:trust_index_history,
        channel: channel, stream: stream,
        trust_index_score: 40, erv_percent: 40, ccv: 100, confidence: 0.85,
        classification: "suspicious", cold_start_status: "full",
        signal_breakdown: {}, calculated_at: 1.day.ago)

      result = described_class.call(channel)
      expect(result[:clean_streams]).to eq(3)
      expect(result[:progress_pct]).to eq(20)  # 3/15 = 20%
    end

    it "returns resolved event as inactive" do
      RehabilitationPenaltyEvent.create!(
        channel: channel,
        initial_penalty: 20,
        applied_at: 30.days.ago,
        resolved_at: 1.day.ago,
        clean_streams_at_resolve: 15
      )

      result = described_class.call(channel)
      expect(result[:active]).to be false
    end

    # TASK-039 Phase A3b (FR-046/047): bonus accelerator + effective progress
    describe "bonus accelerator extension" do
      let(:applied_time) { 10.days.ago }

      before do
        RehabilitationPenaltyEvent.create!(
          channel: channel,
          initial_penalty: 20,
          applied_at: applied_time,
          required_clean_streams: 15
        )
      end

      it "TC-039: response includes bonus hash + effective_progress_pct (raw progress_pct preserved)" do
        # 3 clean streams все qualifying (eng_pct=85, eng_cons_pct=82)
        3.times do |i|
          stream_time = applied_time + (i + 1).days
          stream = create(:stream, channel: channel,
                                   started_at: stream_time, ended_at: stream_time + 1.hour)
          create(:trust_index_history,
                 channel: channel, stream: stream,
                 trust_index_score: 70, erv_percent: 70, ccv: 100, confidence: 0.85,
                 classification: "needs_review", cold_start_status: "full",
                 signal_breakdown: {},
                 calculated_at: stream_time + 1.hour,
                 engagement_percentile_at_end: 85,
                 engagement_consistency_percentile_at_end: 82,
                 category_at_end: "default")
        end

        result = described_class.call(channel)

        # Raw progress_pct unchanged (backwards compat)
        expect(result[:progress_pct]).to eq(20) # 3/15 = 20%

        # Bonus hash present
        expect(result[:bonus]).to be_a(Hash)
        expect(result[:bonus][:bonus_pts_earned]).to eq(3)
        expect(result[:bonus][:bonus_pts_max]).to eq(15)
        expect(result[:bonus][:qualifying_signals]).to be_present

        # Effective progress > raw progress (bonus accelerates).
        # Formula: 3 + (3/15) * 15 * 0.2 = 3 + 0.6 = 3.6 → 24%
        expect(result[:effective_progress_pct]).to be > result[:progress_pct]
        expect(result[:effective_progress_pct]).to eq(24) # round(3.6/15*100)
      end

      it "effective_progress_pct equals raw progress_pct when bonus = 0 (no qualifying)" do
        stream_time = applied_time + 1.day
        stream = create(:stream, channel: channel,
                                 started_at: stream_time, ended_at: stream_time + 1.hour)
        create(:trust_index_history,
               channel: channel, stream: stream,
               trust_index_score: 70, erv_percent: 70, ccv: 100, confidence: 0.85,
               classification: "needs_review", cold_start_status: "full",
               signal_breakdown: {},
               calculated_at: stream_time + 1.hour,
               engagement_percentile_at_end: nil,
               engagement_consistency_percentile_at_end: nil)

        result = described_class.call(channel)
        expect(result[:bonus][:bonus_pts_earned]).to eq(0)
        expect(result[:effective_progress_pct]).to eq(result[:progress_pct])
      end
    end
  end
end
