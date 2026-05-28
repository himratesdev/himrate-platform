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

  # BUG-025: graceful skip when config/deploy.yml is not mounted in the app container.
  # Pre-fix the service raised Errno::ENOENT every cycle → Sidekiq retry 3× → DLQ (474 entries
  # accumulated). Worker now silently no-ops on the :skipped drift_state + logs aggregate marker.
  describe "skipped path (BUG-025)" do
    before do
      allow(AccessoryOps::DriftCheckService).to receive(:call).and_return(
        AccessoryOps::DriftCheckService::Result.new(
          drift_state: :skipped, declared_image: nil, runtime_image: nil
        )
      )
    end

    it "does NOT raise (no Sidekiq retry / DLQ)" do
      expect { worker.perform }.not_to raise_error
    end

    it "does NOT create an event, push an alert, or trigger remediation" do
      expect(AccessoryDriftEvent).not_to receive(:create!)
      expect(AlertmanagerNotifier).not_to receive(:push)
      allow(AccessoryOps::AutoRemediation::TriggerService).to receive(:call)
      worker.perform
      expect(AccessoryOps::AutoRemediation::TriggerService).not_to have_received(:call)
    end

    it "does NOT close an existing open event (paused, not resolved)" do
      open_event = AccessoryDriftEvent.create!(
        destination: "staging", accessory: "redis",
        declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
        detected_at: 1.hour.ago, status: "open"
      )
      worker.perform
      expect(open_event.reload.status).to eq("open")
      expect(open_event.resolved_at).to be_nil
    end

    it "logs an aggregate :skipped marker once per cycle" do
      expect(Rails.logger).to receive(:info).with(
        /drift detection skipped for 1 pair\(s\) .*BUG-025/
      )
      worker.perform
    end
  end
end
