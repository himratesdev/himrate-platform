# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::BonusAcceleratorCalculator do
  let(:channel) { create(:channel) }
  let(:applied_time) { 10.days.ago }
  let(:active_event) do
    RehabilitationPenaltyEvent.create!(
      channel: channel,
      initial_penalty: 20,
      applied_at: applied_time,
      required_clean_streams: 15
    )
  end

  # Helper создаёт post-penalty stream с TIH row + optional snapshot percentiles.
  def create_clean_stream(eng_pct: nil, eng_cons_pct: nil, ti: 70, days_after: 1)
    stream_time = applied_time + days_after.days
    stream = create(:stream, channel: channel,
                             started_at: stream_time, ended_at: stream_time + 1.hour)
    create(:trust_index_history,
           channel: channel, stream: stream,
           trust_index_score: ti, erv_percent: ti, ccv: 100, confidence: 0.85,
           classification: ti >= 50 ? "needs_review" : "suspicious",
           cold_start_status: "full",
           signal_breakdown: {},
           calculated_at: stream_time + 1.hour,
           engagement_percentile_at_end: eng_pct,
           engagement_consistency_percentile_at_end: eng_cons_pct,
           category_at_end: "default")
  end

  describe ".call" do
    # TC-036: 5 clean streams, all qualifying (≥80) → bonus = 5
    it "TC-036: 5 qualifying clean streams → bonus_pts_earned = 5" do
      5.times { |i| create_clean_stream(eng_pct: 85, eng_cons_pct: 82, days_after: i + 1) }

      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(5)
      expect(result[:bonus_pts_max]).to eq(15)
      expect(result[:qualifying_signals][:engagement_percentile]).to eq(85.0)
      expect(result[:qualifying_signals][:engagement_consistency_percentile]).to eq(82.0)
    end

    # TC-037: 20 qualifying → capped at 15 (pts_max)
    it "TC-037: 20 qualifying clean streams → bonus_pts_earned capped at 15" do
      20.times { |i| create_clean_stream(eng_pct: 90, eng_cons_pct: 85, days_after: i + 1) }

      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(15)
    end

    # TC-038: 5 clean streams, percentiles below 80 → bonus = 0
    it "TC-038: percentiles below threshold (80) → bonus_pts_earned = 0" do
      5.times { |i| create_clean_stream(eng_pct: 70, eng_cons_pct: 75, days_after: i + 1) }

      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(0)
      expect(result[:qualifying_signals]).to be_nil
      expect(result[:bonus_description_ru]).to include("Пока нет qualifying")
      expect(result[:bonus_description_en]).to include("No qualifying")
    end

    it "no clean streams → bonus_pts_earned = 0, qualifying_signals = nil" do
      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(0)
      expect(result[:qualifying_signals]).to be_nil
    end

    it "skips streams без snapshots (NULL percentiles → не qualifying)" do
      create_clean_stream(eng_pct: nil, eng_cons_pct: nil, days_after: 1)
      create_clean_stream(eng_pct: 90, eng_cons_pct: 85, days_after: 2)

      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(1) # только 1 stream с snapshots qualifying
    end

    it "excludes pre-penalty streams" do
      pre_stream = create(:stream, channel: channel,
                                   started_at: applied_time - 5.days,
                                   ended_at: applied_time - 5.days + 1.hour)
      create(:trust_index_history,
             channel: channel, stream: pre_stream,
             trust_index_score: 80, erv_percent: 80, ccv: 100, confidence: 0.85,
             classification: "needs_review", cold_start_status: "full",
             signal_breakdown: {},
             calculated_at: applied_time - 5.days + 1.hour,
             engagement_percentile_at_end: 95,
             engagement_consistency_percentile_at_end: 90)

      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(0)
    end

    it "excludes dirty streams (TI < 50) даже с high percentiles" do
      create_clean_stream(eng_pct: 95, eng_cons_pct: 90, ti: 40, days_after: 1)

      result = described_class.call(channel, active_event)
      expect(result[:bonus_pts_earned]).to eq(0)
    end

    it "i18n description с interpolated percentile values при qualifying" do
      3.times { |i| create_clean_stream(eng_pct: 88, eng_cons_pct: 84, days_after: i + 1) }

      result = described_class.call(channel, active_event)
      expect(result[:bonus_description_ru]).to include("+3 баллов")
      expect(result[:bonus_description_ru]).to include("88")
      expect(result[:bonus_description_ru]).to include("84")
      expect(result[:bonus_description_en]).to include("+3 points")
      expect(result[:bonus_description_en]).to include("88")
      expect(result[:bonus_description_en]).to include("84")
    end
  end
end
