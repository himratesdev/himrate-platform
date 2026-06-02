# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ml::Features::StabilitySignals do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:stability) { described_class.new(stream) }

  describe "#call (cold-start — no history)" do
    before do
      # CH stub: no chat data for any stream → privmsg_counts_for_streams returns {}.
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})
    end

    it "TI std nil + reason when < MIN_HISTORY_FOR_VARIANCE TIH rows" do
      result = stability.call
      expect(result[:trust_index_30d_std]).to be_nil
      expect(stability.insufficient_data_reasons[:trust_index_30d_std]).to eq("insufficient_trust_index_history")
    end

    it "chat rate CV nil + reason when < MIN_HISTORY_FOR_VARIANCE streams" do
      result = stability.call
      expect(result[:chat_rate_30d_cv]).to be_nil
      expect(stability.insufficient_data_reasons[:chat_rate_30d_cv]).to eq("insufficient_stream_history")
    end

    it "viewer_retention_avg_sec ALWAYS nil + deferred reason (separate EPIC)" do
      result = stability.call
      expect(result[:viewer_retention_avg_sec]).to be_nil
      expect(stability.insufficient_data_reasons[:viewer_retention_avg_sec])
        .to eq("requires_viewer_session_tracking_separate_epic")
    end
  end

  describe "#call (happy-path — sufficient TIH + sufficient streams)" do
    before do
      # Seed 10 TIH rows linked to past streams with varying TI scores.
      stream_ids = []
      10.times do |i|
        s = create(:stream, channel: channel, ended_at: (i + 1).hours.ago)
        stream_ids << s.id
        TrustIndexHistory.create!(
          channel: channel, stream: s, trust_index_score: 70 + i * 2, # 70, 72, ..., 88
          calculated_at: (i + 1).hours.ago
        )
      end
      # CH chat-rates: vary per stream — base 50 msgs/min ±10
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams) do |ids|
        ids.each_with_index.to_h do |id, i|
          # stream lasted 2 hours = 120 min; want msgs/min = 40..60 → msgs = 4800..7200
          [ id, 4800 + (i * 240) ] # exactly 40, 42, 44, ... msgs/min
        end
      end
      # Anchor stream durations to 2 hours
      Stream.where(channel: channel).where.not(ended_at: nil).find_each do |s|
        s.update!(started_at: s.ended_at - 2.hours)
      end
    end

    it "trust_index_30d_std computed (std of [70..88])" do
      std = stability.call[:trust_index_30d_std]
      # Range 70..88 step 2 — mean=79, variance=(36+25+...+81)/10=33, std≈5.74
      expect(std).to be_a(Numeric)
      expect(std).to be_within(0.1).of(5.7) # approx — depends on population vs sample formula
    end

    it "chat_rate_30d_cv computed numeric in reasonable range" do
      cv = stability.call[:chat_rate_30d_cv]
      expect(cv).to be_a(Numeric)
      expect(cv).to be > 0.0
      expect(cv).to be < 1.0 # ±20% variation around 50 msgs/min → CV ≈ 0.12-0.15
    end

    it "viewer_retention_avg_sec ALWAYS nil — deferred" do
      result = stability.call
      expect(result[:viewer_retention_avg_sec]).to be_nil
      expect(stability.insufficient_data_reasons[:viewer_retention_avg_sec])
        .to eq("requires_viewer_session_tracking_separate_epic")
    end
  end

  describe "#call (boundary — exactly MIN_HISTORY_FOR_VARIANCE — 5 streams)" do
    before do
      5.times do |i|
        s = create(:stream, channel: channel, started_at: (3 + i).hours.ago, ended_at: (1 + i).hours.ago)
        TrustIndexHistory.create!(
          channel: channel, stream: s, trust_index_score: 75 + i,
          calculated_at: (1 + i).hours.ago
        )
      end
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})
    end

    it "TI std computed at boundary (5 = MIN)" do
      std = stability.call[:trust_index_30d_std]
      expect(std).to be_a(Numeric)
      expect(std).to be > 0.0
    end

    it "chat rate CV insufficient — CH returned no privmsgs" do
      cv = stability.call[:chat_rate_30d_cv]
      expect(cv).to be_nil
      expect(stability.insufficient_data_reasons[:chat_rate_30d_cv]).to eq("insufficient_chat_data")
    end
  end

  describe "#call (zero-mean chat rate — pathological)" do
    before do
      10.times do |i|
        s = create(:stream, channel: channel, started_at: (3 + i).hours.ago, ended_at: (1 + i).hours.ago)
      end
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams) do |ids|
        # All streams report 0 privmsgs — filtered out by chat_rates_per_stream → empty rates.
        ids.to_h { |id| [ id, 0 ] }
      end
    end

    it "chat rate CV insufficient — all-zero rates filtered" do
      cv = stability.call[:chat_rate_30d_cv]
      expect(cv).to be_nil
      expect(stability.insufficient_data_reasons[:chat_rate_30d_cv]).to eq("insufficient_chat_data")
    end
  end

  describe "#call (window boundary — 30 streams cap)" do
    before do
      # 35 TIH rows but service only picks last 30.
      35.times do |i|
        s = create(:stream, channel: channel, ended_at: (i + 1).hours.ago)
        TrustIndexHistory.create!(
          channel: channel, stream: s,
          trust_index_score: i < 30 ? 80 : 0, # rows 30-34 have score 0 (older) — should be excluded
          calculated_at: (i + 1).hours.ago
        )
      end
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})
    end

    it "uses only newest 30 TIH rows for std calculation (excludes older 0-score)" do
      std = stability.call[:trust_index_30d_std]
      # If service correctly excludes the 5 older 0-score rows, last 30 are all 80 → std = 0.
      # If it bleeds in the older rows, std would be ~30 (huge gap from 0 to 80).
      expect(std).to be_within(0.001).of(0.0)
    end
  end

  describe "#call (90d outer bound)" do
    before do
      # 10 TIH rows but 5 of them are >90 days old — should be excluded.
      10.times do |i|
        ts = i < 5 ? (i + 1).hours.ago : (100 + i).days.ago
        s = create(:stream, channel: channel, ended_at: ts)
        TrustIndexHistory.create!(
          channel: channel, stream: s,
          trust_index_score: i < 5 ? 80 : 20, # newer=80, older outside-window=20
          calculated_at: ts
        )
      end
      allow(Clickhouse::ChatQueries).to receive(:privmsg_counts_for_streams).and_return({})
    end

    it "ignores TIH rows >90d old" do
      std = stability.call[:trust_index_30d_std]
      # Only 5 in-window rows all 80 → std = 0.
      expect(std).to be_within(0.001).of(0.0)
    end
  end
end
