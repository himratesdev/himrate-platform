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
  end
end
