# frozen_string_literal: true

require "rails_helper"

RSpec.describe AccessoryOps::DriftCheckService do
  describe ".call" do
    before do
      allow(YAML).to receive(:load_file).with(
        described_class::DEPLOY_YML, permitted_classes: [ Symbol ]
      ).and_return(
        "accessories" => { "redis" => { "image" => "redis:7.4-alpine" } }
      )
      allow(AccessoryHostsConfig).to receive(:hosts_for).and_return([ "194.135.85.159" ])
    end

    it "returns :match когда declared == runtime" do
      allow(Open3).to receive(:capture2e).and_return([ "redis:7.4-alpine\n", instance_double(Process::Status, exitstatus: 0) ])
      result = described_class.call(destination: "production", accessory: "redis")
      expect(result.drift_state).to eq(:match)
      expect(result.declared_image).to eq("redis:7.4-alpine")
      expect(result.runtime_image).to eq("redis:7.4-alpine")
    end

    it "returns :mismatch когда declared != runtime" do
      allow(Open3).to receive(:capture2e).and_return([ "redis:7.2-alpine\n", instance_double(Process::Status, exitstatus: 0) ])
      result = described_class.call(destination: "production", accessory: "redis")
      expect(result.drift_state).to eq(:mismatch)
    end

    it "returns :mismatch когда runtime image lookup fails (ssh exit nonzero)" do
      allow(Open3).to receive(:capture2e).and_return([ "ssh: connection error", instance_double(Process::Status, exitstatus: 255) ])
      result = described_class.call(destination: "production", accessory: "redis")
      expect(result.drift_state).to eq(:mismatch)
      expect(result.runtime_image).to be_nil
    end

    it "raises ArgumentError для invalid destination" do
      expect {
        described_class.call(destination: "evilshell", accessory: "redis")
      }.to raise_error(ArgumentError, /invalid destination/)
    end

    it "raises ArgumentError для invalid accessory" do
      expect {
        described_class.call(destination: "production", accessory: "rm -rf /")
      }.to raise_error(ArgumentError, /invalid accessory/)
    end

    it "uses CONTAINER_NAMES literal lookup в SSH command" do
      expect(Open3).to receive(:capture2e) do |*args|
        # Last positional arg = remote shell command
        remote = args.last
        expect(remote).to include("docker inspect himrate-redis")
        [ "redis:7.4-alpine\n", instance_double(Process::Status, exitstatus: 0) ]
      end
      described_class.call(destination: "production", accessory: "redis")
    end
  end

  describe "ALLOWED_ACCESSORIES" do
    it "matches CONTAINER_NAMES.keys (allowlist driven by hash)" do
      expect(described_class::ALLOWED_ACCESSORIES).to eq(described_class::CONTAINER_NAMES.keys)
    end
  end
end
