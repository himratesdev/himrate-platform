# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::AggregationWorker, type: :worker do
  let(:channel) { create(:channel) }
  let(:date) { Date.current - 1.day }

  describe "#perform" do
    it "acquires advisory lock and delegates к DailyBuilder" do
      expect(Trends::Aggregation::DailyBuilder).to receive(:call).with(channel.id, date.to_s)

      described_class.new.perform(channel.id, date.to_s)
    end

    it "skips when lock is busy (concurrent worker)" do
      # Force try_advisory_xact_lock → false через select_value stub.
      allow(ActiveRecord::Base.connection).to receive(:select_value).and_call_original
      allow(ActiveRecord::Base.connection).to receive(:select_value)
        .with(/pg_try_advisory_xact_lock/).and_return(false)

      expect(Trends::Aggregation::DailyBuilder).not_to receive(:call)
      expect { described_class.new.perform(channel.id, date.to_s) }.not_to raise_error
    end

    it "is idempotent — two sequential runs produce single TDA row" do
      create(:stream, channel: channel,
                      started_at: date.beginning_of_day + 2.hours,
                      ended_at: date.beginning_of_day + 4.hours,
                      avg_ccv: 100, peak_ccv: 150)

      expect {
        2.times { described_class.new.perform(channel.id, date.to_s) }
      }.to change(TrendsDailyAggregate, :count).by(1)
    end

    it "accepts Date instance input" do
      expect(Trends::Aggregation::DailyBuilder).to receive(:call).with(channel.id, date.to_s)
      described_class.new.perform(channel.id, date)
    end

    it "uses queue :signals с retry 3" do
      expect(described_class.sidekiq_options["queue"]).to eq("signals")
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end
end
