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
        # PR-A1 (EPIC SCALE ARCHITECTURE Step 2): peak_ccv / avg_ccv columns dropped from
        # streams. DailyBuilder.ccv_aggregates now INNER JOINs post_stream_reports.
        # Each stream gets an explicit PSR with the values that were previously stored on
        # the stream itself — same end-state numerics aggregated by the builder.
        3.times do |i|
          stream = create(:stream, channel: channel,
                                   started_at: target_date.beginning_of_day + (i + 1).hours,
                                   ended_at: target_date.beginning_of_day + (i + 2).hours,
                                   game_name: i.zero? ? "Just Chatting" : "Valorant")
          create(:post_stream_report, stream: stream,
                                      ccv_avg: 100 + (i * 50),
                                      ccv_peak: 200 + (i * 100),
                                      generated_at: stream.ended_at)

          # V1-RETIRE: v2 rows — authenticity (the "% real" heir of ti_*) + native erv count.
          # Latest row (i=2) carries band_row 3 so band_*_at_end picks IT, not an earlier row.
          create(:trust_index_history,
                 channel: channel, stream: stream,
                 authenticity: 70 + (i * 5),
                 erv: 100 + (i * 10),
                 ccv: 100,
                 band_row: i == 2 ? 3 : 4, band_color: "green",
                 signal_breakdown: {},
                 calculated_at: target_date.beginning_of_day + (i + 2).hours)
        end
      end

      it "aggregates authenticity values (avg/std/min/max) and stop-writes ti_* nil" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        # authenticity values: 70, 75, 80 → avg=75, min=70, max=80
        expect(tda.authenticity_avg).to eq(75.0)
        expect(tda.authenticity_min).to eq(70.0)
        expect(tda.authenticity_max).to eq(80.0)
        expect(tda.authenticity_std).to be > 0
        # retired v1 family — written nil
        expect(tda.ti_avg).to be_nil
        expect(tda.ti_min).to be_nil
        expect(tda.ti_max).to be_nil
        expect(tda.ti_std).to be_nil
      end

      it "aggregates the native ERV count and stop-writes erv_*_percent nil" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        # erv counts: 100, 110, 120 → avg = 110
        expect(tda.erv_avg_count).to eq(110.0)
        expect(tda.erv_avg_percent).to be_nil
        expect(tda.erv_min_percent).to be_nil
        expect(tda.erv_max_percent).to be_nil
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

      it "sets band_*_at_end from latest TIH and stop-writes classification_at_end nil" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        expect(tda.band_row_at_end).to eq(3) # latest row (i=2), not an earlier band_row 4
        expect(tda.band_color_at_end).to eq("green")
        expect(tda.classification_at_end).to be_nil # retired v1 column — stop-written
      end
    end

    context "idempotent — re-run upserts same row" do
      before do
        s = create(:stream, channel: channel,
                            started_at: target_date.beginning_of_day + 2.hours,
                            ended_at: target_date.beginning_of_day + 4.hours)
        # PR-A1: peak_ccv / avg_ccv now sourced from PSR.
        create(:post_stream_report, stream: s, ccv_avg: 100, ccv_peak: 150,
          generated_at: s.ended_at)
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
        # Stream на target_date — PR-A1: ccv stats in PSR.
        stream_today = create(:stream, channel: channel,
                                       started_at: target_date.beginning_of_day + 2.hours,
                                       ended_at: target_date.beginning_of_day + 4.hours)
        create(:post_stream_report, stream: stream_today, ccv_avg: 100, ccv_peak: 200,
          generated_at: stream_today.ended_at)
        create(:trust_index_history, channel: channel, stream: stream_today,
                                     authenticity: 75, erv: 75, ccv: 100,
                                     signal_breakdown: {},
                                     calculated_at: target_date.beginning_of_day + 4.hours)

        # Stream previous day — shouldn't count
        stream_prev = create(:stream, channel: channel,
                                      started_at: (target_date - 1.day).beginning_of_day + 2.hours,
                                      ended_at: (target_date - 1.day).beginning_of_day + 4.hours)
        create(:post_stream_report, stream: stream_prev, ccv_avg: 9999, ccv_peak: 9999,
          generated_at: stream_prev.ended_at)
        create(:trust_index_history, channel: channel, stream: stream_prev,
                                     authenticity: 99, erv: 9999, ccv: 9999,
                                     signal_breakdown: {},
                                     calculated_at: (target_date - 1.day).beginning_of_day + 4.hours)
      end

      it "aggregates only target_date data" do
        described_class.call(channel.id, target_date)
        tda = TrendsDailyAggregate.find_by(channel_id: channel.id, date: target_date)

        expect(tda.streams_count).to eq(1)
        expect(tda.authenticity_avg).to eq(75.0) # not 99 from prev day
        expect(tda.ccv_avg).to eq(100)
      end
    end
  end
end
