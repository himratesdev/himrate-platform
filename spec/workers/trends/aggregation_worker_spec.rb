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

    # TASK-039 Phase E1 SRS §10: monitoring events.
    describe "instrumentation" do
      def capture_events(name)
        events = []
        sub = ActiveSupport::Notifications.subscribe(name) { |_, _, _, _, payload| events << payload }
        yield
        events
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end

      it "emits trends.aggregation_worker.completed на успешный run" do
        events = capture_events("trends.aggregation_worker.completed") do
          described_class.new.perform(channel.id, date.to_s)
        end

        expect(events.size).to eq(1)
        expect(events.first[:channel_id]).to eq(channel.id)
        expect(events.first[:date]).to eq(date.to_s)
        expect(events.first[:duration_ms]).to be > 0
        expect(events.first[:lock_contested]).to be false
      end

      it "emits completed с lock_contested=true при locked state" do
        allow_any_instance_of(described_class).to receive(:try_advisory_lock).and_return(false)

        events = capture_events("trends.aggregation_worker.completed") do
          described_class.new.perform(channel.id, date.to_s)
        end

        expect(events.first[:lock_contested]).to be true
      end

      it "emits trends.aggregation_worker.failed + completed на exception" do
        allow(Trends::Aggregation::DailyBuilder).to receive(:call).and_raise(StandardError.new("boom"))

        failed_events = []
        completed_events = []
        sub1 = ActiveSupport::Notifications.subscribe("trends.aggregation_worker.failed") { |_, _, _, _, p| failed_events << p }
        sub2 = ActiveSupport::Notifications.subscribe("trends.aggregation_worker.completed") { |_, _, _, _, p| completed_events << p }

        expect {
          described_class.new.perform(channel.id, date.to_s)
        }.to raise_error(StandardError, "boom")

        expect(failed_events.size).to eq(1)
        expect(failed_events.first[:error_class]).to eq("StandardError")
        expect(completed_events.size).to eq(1)  # ensure всё равно fires
      ensure
        ActiveSupport::Notifications.unsubscribe(sub1) if sub1
        ActiveSupport::Notifications.unsubscribe(sub2) if sub2
      end
    end
  end
end
