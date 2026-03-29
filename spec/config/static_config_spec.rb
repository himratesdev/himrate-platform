# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Static configuration" do
  describe "config/sidekiq.yml" do
    let(:config) do
      YAML.safe_load(
        ERB.new(File.read(Rails.root.join("config/sidekiq.yml"))).result,
        permitted_classes: [ Symbol ]
      )
    end

    it "contains 5 queues" do
      expect(config[:queues].size).to eq(5)
    end

    it "includes required queue names" do
      queue_names = config[:queues].map(&:first)
      expect(queue_names).to include("signals", "chat", "default", "notifications", "monitoring")
    end

    it "prioritizes signals queue highest" do
      signals_weight = config[:queues].find { |q| q.first == "signals" }&.last
      default_weight = config[:queues].find { |q| q.first == "default" }&.last
      expect(signals_weight).to be > default_weight
    end
  end

  describe "config/deploy.yml" do
    let(:deploy) { YAML.safe_load(File.read(Rails.root.join("config/deploy.yml"))) }

    it "env.secret contains FLIPPER_UI_PASSWORD" do
      expect(deploy.dig("env", "secret")).to include("FLIPPER_UI_PASSWORD")
    end

    it "env.secret contains FLIPPER_UI_USER" do
      expect(deploy.dig("env", "secret")).to include("FLIPPER_UI_USER")
    end

    it "env.secret contains ALLOWED_EXTENSION_ID" do
      expect(deploy.dig("env", "secret")).to include("ALLOWED_EXTENSION_ID")
    end

    it "redis accessory uses AOF persistence" do
      redis_cmd = deploy.dig("accessories", "redis", "cmd")
      expect(redis_cmd).to include("--appendonly yes")
    end
  end

  describe "docker-compose.yml" do
    let(:compose) { YAML.safe_load(File.read(Rails.root.join("docker-compose.yml"))) }

    it "redis uses AOF persistence" do
      redis_command = compose.dig("services", "redis", "command")
      expect(redis_command).to include("--appendonly yes")
    end
  end
end
