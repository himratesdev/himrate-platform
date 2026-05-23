# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::NightlyAggregationWorker, type: :worker do
  let(:yesterday) { Date.current - 1 }

  before do
    Flipper.enable(:trends_aggregation_nightly)
    Trends::AggregationWorker.jobs.clear # Sidekiq fake queue accumulates across examples — isolate
  end

  describe "#perform" do
    it "enqueues AggregationWorker for each channel that streamed yesterday" do
      ch1 = create(:channel)
      ch2 = create(:channel)
      create(:stream, channel: ch1, started_at: yesterday.beginning_of_day + 2.hours)
      create(:stream, channel: ch2, started_at: yesterday.end_of_day - 1.hour)

      expect { described_class.new.perform }
        .to change(Trends::AggregationWorker.jobs, :size).by(2)

      enqueued_args = Trends::AggregationWorker.jobs.map { |j| j["args"] }
      expect(enqueued_args).to contain_exactly([ ch1.id, yesterday.to_s ], [ ch2.id, yesterday.to_s ])
    end

    it "does not enqueue for channels that did not stream yesterday" do
      ch = create(:channel)
      create(:stream, channel: ch, started_at: (yesterday - 3.days).beginning_of_day + 1.hour)

      expect { described_class.new.perform }
        .not_to change(Trends::AggregationWorker.jobs, :size)
    end

    it "deduplicates channels with multiple streams yesterday" do
      ch = create(:channel)
      create(:stream, channel: ch, started_at: yesterday.beginning_of_day + 1.hour)
      create(:stream, channel: ch, started_at: yesterday.beginning_of_day + 5.hours)

      expect { described_class.new.perform }
        .to change(Trends::AggregationWorker.jobs, :size).by(1)
    end

    it "is a no-op when the trends_aggregation_nightly flag is disabled" do
      Flipper.disable(:trends_aggregation_nightly)
      ch = create(:channel)
      create(:stream, channel: ch, started_at: yesterday.beginning_of_day + 1.hour)

      expect { described_class.new.perform }
        .not_to change(Trends::AggregationWorker.jobs, :size)
    end

    it "emits a completion instrumentation event with the date and count" do
      events = []
      ActiveSupport::Notifications.subscribe("trends.nightly_aggregation.completed") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      described_class.new.perform

      expect(events.size).to eq(1)
      expect(events.first.payload).to include(date: yesterday.to_s, enqueued: 0)
    ensure
      ActiveSupport::Notifications.unsubscribe("trends.nightly_aggregation.completed")
    end
  end

  describe "sidekiq options" do
    it "runs on the :monitoring queue with retry: 1" do
      expect(described_class.sidekiq_options["queue"]).to eq(:monitoring)
      expect(described_class.sidekiq_options["retry"]).to eq(1)
    end
  end
end
