# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "accessory_ops rake tasks" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  before do
    Rake::Task.tasks.each(&:reenable)
    allow(PrometheusMetrics).to receive(:observe_health_failure)
    allow(PrometheusMetrics).to receive(:observe_rollback)
    allow(PrometheusMetrics).to receive(:delete_grouping)
    allow(AlertmanagerNotifier).to receive(:push)
  end

  describe "accessory_ops:health_verify" do
    it "exits 0 при healthy result сразу" do
      allow(AccessoryOps::HealthCheckService).to receive(:call).and_return(
        instance_double(AccessoryOps::HealthCheckService::Result, healthy?: true, status: "healthy")
      )
      expect {
        Rake::Task["accessory_ops:health_verify"].invoke("staging", "redis", "10")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "exits 1 + observes health_failure после timeout" do
      allow(AccessoryOps::HealthCheckService).to receive(:call).and_return(
        instance_double(AccessoryOps::HealthCheckService::Result, healthy?: false, status: "unhealthy")
      )
      allow_any_instance_of(Object).to receive(:sleep) # skip 10s waits
      expect {
        Rake::Task["accessory_ops:health_verify"].invoke("staging", "redis", "0")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(PrometheusMetrics).to have_received(:observe_health_failure).with(destination: "staging", accessory: "redis")
    end
  end

  describe "accessory_ops:rollback" do
    it "exits 1 + critical alert когда previous_image отсутствует" do
      allow(AccessoryOps::StateService).to receive(:previous_image).and_return(nil)
      expect {
        Rake::Task["accessory_ops:rollback"].invoke("production", "redis")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(AlertmanagerNotifier).to have_received(:push).with(
        labels: hash_including(severity: "critical", event_type: "rollback_no_previous"),
        annotations: kind_of(Hash)
      )
      expect(PrometheusMetrics).to have_received(:observe_rollback).with(
        destination: "production", accessory: "redis", result: "no_previous"
      )
    end

    it "exits 0 когда kamal accessory boot succeeds" do
      allow(AccessoryOps::StateService).to receive(:previous_image).and_return("redis:7.2-alpine")
      allow_any_instance_of(Object).to receive(:system).with("kamal", "accessory", "boot", "redis", "-d", "production").and_return(true)
      expect {
        Rake::Task["accessory_ops:rollback"].invoke("production", "redis")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      expect(PrometheusMetrics).to have_received(:observe_rollback).with(
        destination: "production", accessory: "redis", result: "success"
      )
    end

    it "exits 1 + critical alert когда kamal command fails" do
      allow(AccessoryOps::StateService).to receive(:previous_image).and_return("redis:7.2-alpine")
      allow_any_instance_of(Object).to receive(:system).and_return(false)
      expect {
        Rake::Task["accessory_ops:rollback"].invoke("production", "redis")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      expect(AlertmanagerNotifier).to have_received(:push).with(
        labels: hash_including(severity: "critical", event_type: "rollback_failed"),
        annotations: kind_of(Hash)
      )
    end
  end

  describe "accessory_ops:state:update_after_health" do
    it "delegates StateService и prints state info" do
      record = AccessoryState.create!(destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine")
      expect(AccessoryOps::StateService).to receive(:update_after_health_check).with(
        destination: "staging", accessory: "redis", image: "redis:7.4-alpine", status: "healthy"
      ).and_return(record)
      expect {
        Rake::Task["accessory_ops:state:update_after_health"].invoke("staging", "redis", "redis:7.4-alpine", "healthy")
      }.to output(/state_updated/).to_stdout
    end
  end

  describe "accessory_ops:state:refresh" do
    it "reads runtime image via DriftCheckService и обновляет state" do
      allow(AccessoryOps::DriftCheckService).to receive(:call).and_return(
        AccessoryOps::DriftCheckService::Result.new(
          drift_state: :match, declared_image: "redis:7.4-alpine", runtime_image: "redis:7.4-alpine"
        )
      )
      record = AccessoryState.create!(destination: "staging", accessory: "redis", current_image: "redis:7.2-alpine")
      expect(AccessoryOps::StateService).to receive(:update_after_health_check).and_return(record)
      expect {
        Rake::Task["accessory_ops:state:refresh"].invoke("staging", "redis", "healthy")
      }.to output(/state_refreshed/).to_stdout
    end

    it "exits 1 когда runtime_image не доступен" do
      allow(AccessoryOps::DriftCheckService).to receive(:call).and_return(
        AccessoryOps::DriftCheckService::Result.new(
          drift_state: :mismatch, declared_image: "redis:7.4-alpine", runtime_image: nil
        )
      )
      expect {
        Rake::Task["accessory_ops:state:refresh"].invoke("staging", "redis")
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  describe "accessory_ops:downtime:start" do
    it "creates row и outputs event_id" do
      expect {
        Rake::Task["accessory_ops:downtime:start"].invoke("production", "redis", "drift", nil)
      }.to change(AccessoryDowntimeEvent, :count).by(1).and output(/[a-f0-9-]{36}/).to_stdout
    end
  end

  describe "accessory_ops:downtime:end" do
    it "sets ended_at + computes duration_seconds" do
      event = AccessoryDowntimeEvent.create!(
        destination: "production", accessory: "redis",
        started_at: 60.seconds.ago, source: "drift"
      )
      expect {
        Rake::Task["accessory_ops:downtime:end"].invoke(event.id)
      }.to output(/downtime_closed/).to_stdout
      event.reload
      expect(event.ended_at).to be_present
      expect(event.duration_seconds).to be >= 60
    end
  end

  describe "accessory_ops:notify" do
    it "invokes AlertmanagerNotifier.push с structured labels" do
      Rake::Task["accessory_ops:notify"].invoke(
        "drift_open", "warning", "production", "redis", "Test summary", "Details"
      )
      expect(AlertmanagerNotifier).to have_received(:push).with(
        labels: hash_including(event_type: "drift_open", severity: "warning",
                               destination: "production", accessory: "redis"),
        annotations: hash_including(summary: "Test summary", description: "Details")
      )
    end
  end

  describe "accessory_ops:auto_remediation:enable / :disable" do
    it "enable adds + enables Flipper flag" do
      Rake::Task["accessory_ops:auto_remediation:enable"].invoke
      expect(Flipper.enabled?(:accessory_auto_remediation)).to be true
    end

    it "disable turns off Flipper flag" do
      Flipper.add(:accessory_auto_remediation)
      Flipper.enable(:accessory_auto_remediation)
      Rake::Task["accessory_ops:auto_remediation:disable"].invoke
      expect(Flipper.enabled?(:accessory_auto_remediation)).to be false
    end
  end

  describe "accessory_ops:metrics:cleanup_stale_groupings" do
    it "deletes pushgateway groupings для stale pairs (last_health_check_at старше cutoff)" do
      AccessoryState.create!(
        destination: "production", accessory: "redis", current_image: "redis:7.4-alpine",
        last_health_check_at: 10.days.ago
      )
      AccessoryState.create!(
        destination: "staging", accessory: "db", current_image: "postgres:16",
        last_health_check_at: 1.hour.ago # active
      )
      Rake::Task["accessory_ops:metrics:cleanup_stale_groupings"].invoke("7")
      # 5 jobs × 1 stale pair = 5 delete_grouping calls
      expect(PrometheusMetrics).to have_received(:delete_grouping).exactly(5).times
    end
  end
end
