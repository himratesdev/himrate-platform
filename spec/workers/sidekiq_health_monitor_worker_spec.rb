# frozen_string_literal: true

require "rails_helper"

RSpec.describe SidekiqHealthMonitorWorker do
  let(:worker) { described_class.new }

  before do
    allow(AlertmanagerNotifier).to receive(:push)
  end

  describe "#perform" do
    it "alerts когда cron job не зарегистрирован" do
      allow(Sidekiq::Cron::Job).to receive(:find).with("accessory_drift_detector").and_return(nil)
      worker.perform
      expect(AlertmanagerNotifier).to have_received(:push).with(
        labels: hash_including(event_type: "drift_detector_unscheduled"),
        annotations: kind_of(Hash)
      )
    end

    it "alerts когда last_enqueue_time старше STALE_THRESHOLD (2h)" do
      cron_job = double("CronJob", last_enqueue_time: 3.hours.ago)
      allow(Sidekiq::Cron::Job).to receive(:find).with("accessory_drift_detector").and_return(cron_job)
      worker.perform
      expect(AlertmanagerNotifier).to have_received(:push).with(
        labels: hash_including(event_type: "drift_detector_stale"),
        annotations: kind_of(Hash)
      )
    end

    it "не alert если last_enqueue_time свежий (<2h)" do
      cron_job = double("CronJob", last_enqueue_time: 30.minutes.ago)
      allow(Sidekiq::Cron::Job).to receive(:find).with("accessory_drift_detector").and_return(cron_job)
      worker.perform
      expect(AlertmanagerNotifier).not_to have_received(:push)
    end
  end
end
