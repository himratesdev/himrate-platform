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

    # CR N-2: stub behavior-focused method вместо brittle SQL regex
    it "re-enqueues с 30s delay when lock busy" do
      allow_any_instance_of(described_class).to receive(:try_advisory_lock).and_return(false)

      expect(Trends::Aggregation::DailyBuilder).not_to receive(:call)
      expect(described_class).to receive(:perform_in).with(30.seconds, channel.id, date.to_s)

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
      expect(described_class.sidekiq_options["queue"]).to eq(:signals)
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end
  end
end
