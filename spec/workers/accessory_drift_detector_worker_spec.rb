# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryDriftDetectorWorker do
  let(:worker) { described_class.new }

  before do
    Flipper.add(:accessory_drift_detection)
    Flipper.enable(:accessory_drift_detection)
    Flipper.add(:accessory_auto_remediation)
    Flipper.enable(:accessory_auto_remediation)
    allow(AccessoryHostsConfig).to receive(:destinations).and_return([ "staging" ])
    stub_const("AccessoryDriftDetectorWorker::ACCESSORIES", [ "redis" ])
    allow(AlertmanagerNotifier).to receive(:push)
  end

  describe "Flipper gate" do
    it "skips entire run когда :accessory_drift_detection disabled" do
      Flipper.disable(:accessory_drift_detection)
      expect(AccessoryOps::DriftCheckService).not_to receive(:call)
      worker.perform
    end
  end

  describe "match path" do
    before do
      allow(AccessoryOps::DriftCheckService).to receive(:call).and_return(
        AccessoryOps::DriftCheckService::Result.new(
          drift_state: :match, declared_image: "redis:7.4-alpine", runtime_image: "redis:7.4-alpine"
        )
      )
    end

    it "не открывает event когда drift state = match" do
      expect { worker.perform }.not_to change(AccessoryDriftEvent, :count)
    end

    it "closes existing open event с resolved_at" do
      open_event = AccessoryDriftEvent.create!(
        destination: "staging", accessory: "redis",
        declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
        detected_at: 2.hours.ago, status: "open"
      )
      worker.perform
      expect(open_event.reload).to have_attributes(status: "resolved")
      expect(open_event.resolved_at).to be_present
    end
  end

  describe "mismatch path" do
    before do
      allow(AccessoryOps::DriftCheckService).to receive(:call).and_return(
        AccessoryOps::DriftCheckService::Result.new(
          drift_state: :mismatch, declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine"
        )
      )
      allow(AccessoryOps::AutoRemediation::TriggerService).to receive(:call)
    end

    it "creates open drift event + alert + remediation trigger" do
      expect {
        worker.perform
      }.to change(AccessoryDriftEvent, :count).by(1)

      expect(AlertmanagerNotifier).to have_received(:push)
      expect(AccessoryOps::AutoRemediation::TriggerService).to have_received(:call).with(
        destination: "staging", accessory: "redis", drift_event_id: kind_of(String)
      )
    end

    it "idempotent: no duplicate event при existing open" do
      AccessoryDriftEvent.create!(
        destination: "staging", accessory: "redis",
        declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
        detected_at: 1.hour.ago, status: "open"
      )
      expect { worker.perform }.not_to change(AccessoryDriftEvent, :count)
      expect(AccessoryOps::AutoRemediation::TriggerService).not_to have_received(:call)
    end
  end

  describe "error handling" do
    it "raises so Sidekiq retry kicks в" do
      allow(AccessoryOps::DriftCheckService).to receive(:call).and_raise(StandardError, "ssh failed")
      expect { worker.perform }.to raise_error(StandardError, "ssh failed")
    end
  end
end
