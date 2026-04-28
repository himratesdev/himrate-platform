# frozen_string_literal: true

require "rails_helper"

RSpec.describe PrometheusMetrics do
  let(:base) { "http://himrate-prometheus-pushgateway:9091" }

  before do
    stub_request(:post, %r{#{base}/metrics/.*}).to_return(status: 200)
    stub_request(:delete, %r{#{base}/metrics/.*}).to_return(status: 202)
  end

  describe ".observe_ops" do
    it "POSTs к pushgateway с per-pair grouping" do
      described_class.observe_ops(
        destination: "production", accessory: "redis",
        action: "reboot", result: "success", duration_seconds: 12.5
      )
      expect(WebMock).to have_requested(:post, "#{base}/metrics/job/accessory_ops/destination/production/accessory/redis")
        .with { |req|
          req.body.include?("accessory_ops_last_action_duration_seconds") &&
            req.body.include?("12.5") &&
            req.body.include?(%(action="reboot")) &&
            req.body.include?(%(result="success"))
        }
    end

    it "пропускает duration metric когда duration_seconds nil" do
      described_class.observe_ops(
        destination: "staging", accessory: "db",
        action: "stop", result: "success"
      )
      expect(WebMock).to have_requested(:post, %r{#{base}/metrics/job/accessory_ops/.*})
        .with { |req|
          !req.body.include?("accessory_ops_last_action_duration_seconds") &&
            req.body.include?("accessory_ops_last_action_timestamp_seconds")
        }
    end
  end

  describe ".observe_drift_active" do
    it "pushes 1 для open drift" do
      described_class.observe_drift_active(destination: "production", accessory: "redis", value: 1)
      expect(WebMock).to have_requested(:post, "#{base}/metrics/job/accessory_drift/destination/production/accessory/redis")
        .with(body: /accessory_drift_active.*1/m)
    end

    it "pushes 0 для resolved drift" do
      described_class.observe_drift_active(destination: "production", accessory: "redis", value: 0)
      expect(WebMock).to have_requested(:post, %r{#{base}.*}).with(body: /accessory_drift_active.*0/m)
    end
  end

  describe ".observe_drift_mttr" do
    it "pushes seconds gauge" do
      described_class.observe_drift_mttr(destination: "staging", accessory: "db", seconds: 1234)
      expect(WebMock).to have_requested(:post, "#{base}/metrics/job/accessory_drift/destination/staging/accessory/db")
        .with(body: /accessory_drift_last_mttr_seconds.*1234/m)
    end
  end

  describe ".observe_health_failure" do
    it "pushes Unix timestamp gauge" do
      described_class.observe_health_failure(destination: "production", accessory: "loki")
      expect(WebMock).to have_requested(:post, "#{base}/metrics/job/accessory_health/destination/production/accessory/loki")
        .with(body: /accessory_health_last_failure_timestamp_seconds/)
    end
  end

  describe ".observe_rollback" do
    it "pushes timestamp + result label" do
      described_class.observe_rollback(destination: "production", accessory: "redis", result: "success")
      expect(WebMock).to have_requested(:post, "#{base}/metrics/job/accessory_rollback/destination/production/accessory/redis")
        .with { |req| req.body.include?(%(result="success")) }
    end
  end

  describe ".observe_downtime_cost" do
    it "pushes float USD gauge" do
      described_class.observe_downtime_cost(destination: "production", accessory: "db", cost_usd: 41.67)
      expect(WebMock).to have_requested(:post, "#{base}/metrics/job/accessory_cost/destination/production/accessory/db")
        .with(body: /accessory_downtime_cost_usd.*41\.67/m)
    end
  end

  describe ".delete_grouping" do
    it "DELETEs к pushgateway endpoint" do
      result = described_class.delete_grouping(job: "accessory_drift", grouping: { destination: "staging", accessory: "redis" })
      expect(result).to eq(:ok)
      expect(WebMock).to have_requested(:delete, "#{base}/metrics/job/accessory_drift/destination/staging/accessory/redis")
    end
  end

  describe "label sanitization" do
    it "escapes special chars в pushgateway URL path" do
      described_class.observe_drift_active(destination: "staging/x", accessory: "redis;rm", value: 1)
      # forbidden chars (/, ;) → underscore
      expect(WebMock).to have_requested(:post, %r{/destination/staging_x/accessory/redis_rm})
    end
  end

  describe "failure handling" do
    it "не raise когда pushgateway unreachable" do
      stub_request(:post, %r{#{base}.*}).to_raise(Errno::ECONNREFUSED.new("blocked"))
      expect {
        described_class.observe_drift_active(destination: "staging", accessory: "redis", value: 1)
      }.not_to raise_error
    end

    it "не raise при non-2xx ответе (pushgateway returns log warn)" do
      stub_request(:post, %r{#{base}.*}).to_return(status: 500)
      expect {
        described_class.observe_drift_active(destination: "staging", accessory: "redis", value: 1)
      }.not_to raise_error
    end
  end
end
