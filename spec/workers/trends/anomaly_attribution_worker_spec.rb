# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::AnomalyAttributionWorker, type: :worker do
  let(:channel) { create(:channel) }
  let(:stream) { create(:stream, channel: channel) }
  let(:anomaly) { create(:anomaly, stream: stream) }

  describe "#perform" do
    it "delegates к Trends::Attribution::Pipeline" do
      expect(Trends::Attribution::Pipeline).to receive(:call).with(anomaly).and_return([])

      described_class.new.perform(anomaly.id)
    end

    it "no-ops если anomaly not found" do
      expect(Trends::Attribution::Pipeline).not_to receive(:call)
      expect { described_class.new.perform(SecureRandom.uuid) }.not_to raise_error
    end

    it "uses queue :signals с retry 3" do
      expect(described_class.sidekiq_options["queue"]).to eq(:signals)
      expect(described_class.sidekiq_options["retry"]).to eq(3)
    end

    # TASK-039 Phase E1 SRS §10: monitoring events.
    # CR S-3: unified ensure pattern — completed фёрит на КАЖДЫЙ perform
    # (success/failure/not_found) + отдельный failed marker.
    describe "instrumentation" do
      it "emits completed с found=true + attributions_count на успешный run" do
        allow(Trends::Attribution::Pipeline).to receive(:call).with(anomaly).and_return([])

        events = []
        sub = ActiveSupport::Notifications.subscribe("trends.anomaly_attribution_worker.completed") do |_, _, _, _, payload|
          events << payload
        end

        described_class.new.perform(anomaly.id)

        expect(events.size).to eq(1)
        expect(events.first[:anomaly_id]).to eq(anomaly.id)
        expect(events.first[:found]).to be true
        expect(events.first[:attributions_count]).to eq(0)
        expect(events.first[:duration_ms]).to be > 0
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end

      it "emits completed с found=false для missing anomaly (no silent no-op)" do
        events = []
        sub = ActiveSupport::Notifications.subscribe("trends.anomaly_attribution_worker.completed") do |_, _, _, _, p|
          events << p
        end

        described_class.new.perform(SecureRandom.uuid)

        expect(events.size).to eq(1)
        expect(events.first[:found]).to be false
        expect(events.first[:attributions_count]).to eq(0)
      ensure
        ActiveSupport::Notifications.unsubscribe(sub) if sub
      end

      it "emits failed + completed на exception + re-raises" do
        allow(Trends::Attribution::Pipeline).to receive(:call).and_raise(StandardError.new("pipeline boom"))

        failed_events = []
        completed_events = []
        sub1 = ActiveSupport::Notifications.subscribe("trends.anomaly_attribution_worker.failed") { |_, _, _, _, p| failed_events << p }
        sub2 = ActiveSupport::Notifications.subscribe("trends.anomaly_attribution_worker.completed") { |_, _, _, _, p| completed_events << p }

        expect { described_class.new.perform(anomaly.id) }.to raise_error(StandardError, "pipeline boom")
        expect(failed_events.size).to eq(1)
        expect(failed_events.first[:error_class]).to eq("StandardError")
        expect(completed_events.size).to eq(1)
      ensure
        ActiveSupport::Notifications.unsubscribe(sub1) if sub1
        ActiveSupport::Notifications.unsubscribe(sub2) if sub2
      end
    end
  end
end
