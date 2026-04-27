# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryOps::HealthCheckService do
  before do
    allow(AccessoryHostsConfig).to receive(:hosts_for).and_return([ "194.135.85.159" ])
  end

  describe ".call" do
    it "returns healthy=true когда SSH command exits 0" do
      allow(Open3).to receive(:capture2e).and_return([ "PONG\n", instance_double(Process::Status, exitstatus: 0) ])
      result = described_class.call(destination: "production", accessory: "redis")
      expect(result).to be_healthy
      expect(result.status).to eq("healthy")
      expect(result.raw_output).to eq("PONG")
    end

    it "returns healthy=false когда SSH command fails" do
      allow(Open3).to receive(:capture2e).and_return([ "Connection refused", instance_double(Process::Status, exitstatus: 1) ])
      result = described_class.call(destination: "production", accessory: "db")
      expect(result).not_to be_healthy
      expect(result.status).to eq("unhealthy")
    end

    it "returns no_check_method когда accessory unknown" do
      result = described_class.call(destination: "production", accessory: "unsupported_thing")
      expect(result.status).to eq("no_check_method")
      expect(result).not_to be_healthy
    end

    it "ssh failure caught и returned as unhealthy" do
      allow(Open3).to receive(:capture2e).and_raise(Errno::ECONNREFUSED.new("blocked"))
      result = described_class.call(destination: "production", accessory: "redis")
      expect(result).not_to be_healthy
      expect(result.raw_output).to include("Errno::ECONNREFUSED")
    end
  end

  describe "HEALTH_COMMANDS strategy hash" do
    it "covers all 8 supported accessories" do
      expect(described_class::HEALTH_COMMANDS.keys).to match_array(
        %w[db redis grafana prometheus prometheus-pushgateway loki promtail alertmanager]
      )
    end
  end
end
