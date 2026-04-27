# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryOps::AutoRemediation::TriggerService do
  let(:dispatch_url) do
    "https://api.github.com/repos/himratesdev/himrate-platform/actions/workflows/accessory-ops.yml/dispatches"
  end
  let(:drift_event) do
    AccessoryDriftEvent.create!(
      destination: "production", accessory: "redis",
      declared_image: "redis:7.4-alpine", runtime_image: "redis:7.2-alpine",
      detected_at: Time.current, status: "open"
    )
  end

  before do
    Flipper.add(:accessory_auto_remediation)
    Flipper.enable(:accessory_auto_remediation)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AUTO_TRIGGER_GH_PAT").and_return("test_pat")
  end

  describe "Flipper gate" do
    it "skip:disabled когда flag off — без log row" do
      Flipper.disable(:accessory_auto_remediation)
      expect {
        result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
        expect(result.result).to eq(:disabled)
      }.not_to change(AutoRemediationLog, :count)
    end
  end

  describe "auto-disabled state" do
    it "skips если any prior log carries disabled_at" do
      AutoRemediationLog.create!(
        destination: "production", accessory: "redis",
        triggered_at: 1.hour.ago, result: "auto_disabled",
        attempt_number: 4, disabled_at: 1.hour.ago
      )
      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      expect(result.result).to eq(:auto_disabled)
    end
  end

  describe "cool-down window (24h)" do
    it "skip:skip_cooldown если triggered event recent (<24h)" do
      AutoRemediationLog.create!(
        destination: "production", accessory: "redis",
        triggered_at: 1.hour.ago, result: "triggered", attempt_number: 1
      )
      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      expect(result.result).to eq(:skip_cooldown)
      expect(WebMock).not_to have_requested(:post, dispatch_url)
    end

    it "passes cool-down если triggered older 24h" do
      AutoRemediationLog.create!(
        destination: "production", accessory: "redis",
        triggered_at: 25.hours.ago, result: "triggered", attempt_number: 1
      )
      stub_request(:post, dispatch_url).to_return(status: 204)
      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      expect(result.result).to eq(:triggered)
    end
  end

  describe "max-attempts cascade (3/72h)" do
    it "auto-disables после 3 triggered в 72h" do
      3.times do |i|
        AutoRemediationLog.create!(
          destination: "production", accessory: "redis",
          triggered_at: (i + 30).hours.ago, # отступаем от cooldown окна
          result: "triggered", attempt_number: i + 1
        )
      end
      expect {
        result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
        expect(result.result).to eq(:skip_max_attempts)
      }.to change { AutoRemediationLog.where(result: "auto_disabled").count }.by(1)

      disabled_log = AutoRemediationLog.where(result: "auto_disabled").last
      expect(disabled_log.disabled_at).to be_present
      expect(disabled_log.disable_reason).to eq("max_attempts_exhausted_3_in_72h")
    end
  end

  describe "GitHub workflow_dispatch API" do
    it "POSTs к dispatches endpoint и creates triggered log" do
      stub_request(:post, dispatch_url)
        .with(headers: { "Authorization" => "Bearer test_pat", "Content-Type" => "application/json" })
        .to_return(status: 204)

      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      expect(result.result).to eq(:triggered)
      log = AutoRemediationLog.last
      expect(log.result).to eq("triggered")
      expect(log.attempt_number).to eq(1)
      expect(log.drift_event_id).to eq(drift_event.id)
    end

    it "logs api_error на 422 response" do
      stub_request(:post, dispatch_url).to_return(status: 422, body: '{"message":"workflow not found"}')
      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      expect(result.result).to eq(:api_error)
      expect(AutoRemediationLog.last.result).to eq("api_error")
    end

    it "logs api_error при network exception" do
      stub_request(:post, dispatch_url).to_raise(Errno::ECONNREFUSED.new("blocked"))
      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      expect(result.result).to eq(:api_error)
      expect(AutoRemediationLog.last.result).to eq("api_error")
    end

    it "increments attempt_number per (destination, accessory)" do
      AutoRemediationLog.create!(
        destination: "production", accessory: "redis",
        triggered_at: 30.hours.ago, # вне cooldown
        result: "triggered", attempt_number: 1
      )
      stub_request(:post, dispatch_url).to_return(status: 204)
      result = described_class.call(destination: "production", accessory: "redis", drift_event_id: drift_event.id)
      new_log = AutoRemediationLog.find(result.log_id)
      expect(new_log.attempt_number).to eq(2)
    end
  end
end
