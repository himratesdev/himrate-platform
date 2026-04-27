# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

RSpec.describe AccessoryOps::StateCacheService do
  let(:tmp_cache_dir) { Dir.mktmpdir("state_cache_spec") }

  before do
    stub_const("AccessoryOps::StateCacheService::CACHE_DIR", tmp_cache_dir)
  end

  after do
    FileUtils.rm_rf(tmp_cache_dir)
  end

  describe ".write_one" do
    let(:state) do
      AccessoryState.create!(
        destination: "production",
        accessory: "redis",
        current_image: "redis:7.4-alpine",
        previous_image: "redis:7.2-alpine",
        last_health_check_at: Time.current,
        last_health_status: "healthy"
      )
    end

    it "writes JSON file with payload" do
      path = described_class.write_one(state)
      expect(File.exist?(path)).to be true
      payload = JSON.parse(File.read(path))
      expect(payload).to include(
        "destination" => "production",
        "accessory" => "redis",
        "current_image" => "redis:7.4-alpine",
        "previous_image" => "redis:7.2-alpine",
        "last_health_status" => "healthy"
      )
    end

    it "файл carries 0o600 permissions" do
      path = described_class.write_one(state)
      mode = File.stat(path).mode & 0o777
      expect(mode).to eq(0o600)
    end

    it "filename pattern <destination>_<accessory>.json" do
      path = described_class.write_one(state)
      expect(File.basename(path)).to eq("production_redis.json")
    end
  end

  describe ".write_all" do
    it "writes one file per AccessoryState row" do
      AccessoryState.create!(destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine")
      AccessoryState.create!(destination: "production", accessory: "db", current_image: "postgres:16")
      described_class.write_all
      expect(Dir.glob(File.join(tmp_cache_dir, "*.json")).size).to eq(2)
    end
  end

  describe ".read" do
    it "returns parsed JSON payload from cache" do
      state = AccessoryState.create!(destination: "staging", accessory: "redis", current_image: "redis:7.4-alpine")
      described_class.write_one(state)
      payload = described_class.read(destination: "staging", accessory: "redis")
      expect(payload["current_image"]).to eq("redis:7.4-alpine")
    end

    it "returns nil когда cache file missing" do
      expect(described_class.read(destination: "staging", accessory: "missing")).to be_nil
    end
  end
end
