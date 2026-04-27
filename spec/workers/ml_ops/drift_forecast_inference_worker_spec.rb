# frozen_string_literal: true

require "rails_helper"

RSpec.describe MlOps::DriftForecastInferenceWorker do
  describe "#perform" do
    it "delegates к MlOps::DriftForecastInferenceService.call" do
      expect(MlOps::DriftForecastInferenceService).to receive(:call)
      described_class.new.perform
    end
  end

  describe "Sidekiq configuration" do
    it "queues to :default" do
      expect(described_class.get_sidekiq_options["queue"]).to eq(:default)
    end

    it "configures retry: 2" do
      expect(described_class.get_sidekiq_options["retry"]).to eq(2)
    end

    it "include Sidekiq::Job (cron klass.new.perform pattern works)" do
      expect(described_class.ancestors).to include(Sidekiq::Job)
      expect(described_class.new).to respond_to(:perform)
    end
  end
end
