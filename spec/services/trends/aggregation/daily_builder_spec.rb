# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Aggregation::DailyBuilder, type: :service do
  let(:channel) { create(:channel) }
  let(:target_date) { Date.current - 2.days }

  describe ".call" do
    context "when no streams / TIH на date" do
      it "creates TDA row с counts=0 и NULL aggregates" do
        expect {
          described_class.call(channel.id, target_date)
        }.to change(TrendsDailyAggregate, :count).by(1)

        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)
        expect(tda.streams_count).to eq(0)
        expect(tda.ti_avg).to be_nil
        expect(tda.erv_avg_percent).to be_nil
        expect(tda.ccv_avg).to be_nil
        expect(tda.categories).to eq({})
        expect(tda.classification_at_end).to be_nil
        expect(tda.schema_version).to eq(TrendsDailyAggregate::SUPPORTED_SCHEMA_VERSIONS.max)
      end
    end

    context "with 3 streams + TIH rows на date" do
      before do
        3.times do |i|
          stream = create(:stream, channel: channel,
                                   started_at: target_date.beginning_of_day + (i + 1).hours,
                                   ended_at: target_date.beginning_of_day + (i + 2).hours,
                                   avg_ccv: 100 + (i * 50),
                                   peak_ccv: 200 + (i * 100),
                                   game_name: i.zero? ? "Just Chatting" : "Valorant")

          create(:trust_index_history,
                 channel: channel, stream: stream,
                 trust_index_score: 70 + (i * 5),
                 erv_percent: 75 + (i * 3),
                 ccv: 100, confidence: 0.85,
                 classification: "needs_review", cold_start_status: "full",
                 signal_breakdown: {},
                 calculated_at: target_date.beginning_of_day + (i + 2).hours)
        end
      end

      it "aggregates TI values (avg/std/min/max)" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        # TI values: 70, 75, 80 → avg=75, min=70, max=80
        expect(tda.ti_avg).to eq(75.0)
        expect(tda.ti_min).to eq(70.0)
        expect(tda.ti_max).to eq(80.0)
        expect(tda.ti_std).to be > 0
      end

      it "aggregates ERV values" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        # ERV values: 75, 78, 81
        expect(tda.erv_avg_percent).to eq(78.0)
        expect(tda.erv_min_percent).to eq(75.0)
        expect(tda.erv_max_percent).to eq(81.0)
      end

      it "aggregates CCV values" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        # avg_ccv: 100, 150, 200 → avg = 150. peak_ccv: 200, 300, 400 → max = 400
        expect(tda.ccv_avg).to eq(150)
        expect(tda.ccv_peak).to eq(400)
      end

      it "counts streams + builds categories breakdown" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        expect(tda.streams_count).to eq(3)
        expect(tda.categories).to eq({ "Just Chatting" => 1, "Valorant" => 2 })
      end

      it "sets classification_at_end from latest TIH" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        expect(tda.classification_at_end).to eq("needs_review")
      end
    end

    context "idempotent — re-run upserts same row" do
      before do
        create(:stream, channel: channel,
                        started_at: target_date.beginning_of_day + 2.hours,
                        ended_at: target_date.beginning_of_day + 4.hours,
                        avg_ccv: 100, peak_ccv: 150)
      end

      it "doesn't create duplicate TDA rows" do
        expect {
          2.times { described_class.call(channel.id, target_date) }
        }.to change(TrendsDailyAggregate, :count).by(1)
      end
    end

    context "with String date input" do
      it "parses date string correctly" do
        expect {
          described_class.call(channel.id, target_date.to_s)
        }.to change(TrendsDailyAggregate, :count).by(1)

        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)
        expect(tda).to be_present
      end
    end

    context "excludes streams/TIH из других дат" do
      before do
        # Stream на target_date
        stream_today = create(:stream, channel: channel,
                                       started_at: target_date.beginning_of_day + 2.hours,
                                       ended_at: target_date.beginning_of_day + 4.hours,
                                       avg_ccv: 100, peak_ccv: 200)
        create(:trust_index_history, channel: channel, stream: stream_today,
                                     trust_index_score: 75, erv_percent: 75, ccv: 100,
                                     confidence: 0.85, classification: "needs_review",
                                     cold_start_status: "full", signal_breakdown: {},
                                     calculated_at: target_date.beginning_of_day + 4.hours)

        # Stream previous day — shouldn't count
        stream_prev = create(:stream, channel: channel,
                                      started_at: (target_date - 1.day).beginning_of_day + 2.hours,
                                      ended_at: (target_date - 1.day).beginning_of_day + 4.hours,
                                      avg_ccv: 9999, peak_ccv: 9999)
        create(:trust_index_history, channel: channel, stream: stream_prev,
                                     trust_index_score: 99, erv_percent: 99, ccv: 9999,
                                     confidence: 0.85, classification: "trusted",
                                     cold_start_status: "full", signal_breakdown: {},
                                     calculated_at: (target_date - 1.day).beginning_of_day + 4.hours)
      end

      it "aggregates only target_date data" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        expect(tda.streams_count).to eq(1)
        expect(tda.ti_avg).to eq(75.0) # not 99 from prev day
        expect(tda.ccv_avg).to eq(100)
      end
    end
  end
end
