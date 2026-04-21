# frozen_string_literal: true

require "rails_helper"

RSpec.describe Trends::Cache::KeyBuilder do
  let(:channel_id) { "00000000-0000-0000-0000-000000000001" }

  before do
    SignalConfiguration.upsert_all([
      { signal_type: "trends", category: "cache", param_name: "schema_version", param_value: 2,
        created_at: Time.current, updated_at: Time.current }
    ], unique_by: %i[signal_type category param_name], on_duplicate: :skip)
  end

  describe ".call" do
    it "builds versioned key с schema_version + epoch" do
      allow_any_instance_of(described_class).to receive(:current_epoch).and_return(0)

      key = described_class.call(channel_id: channel_id, endpoint: "erv", period: "30d")

      expect(key).to start_with("trends:#{channel_id}:erv:30d:daily:v2:e")
    end

    it "includes granularity в ключ" do
      allow_any_instance_of(described_class).to receive(:current_epoch).and_return(5)

      key = described_class.call(channel_id: channel_id, endpoint: "erv", period: "30d", granularity: "per_stream")

      expect(key).to eq("trends:#{channel_id}:erv:30d:per_stream:v2:e5")
    end
  end

  describe ".ttl_for" do
    it "returns 30m для 7d/30d" do
      expect(described_class.ttl_for("7d")).to eq(30.minutes)
      expect(described_class.ttl_for("30d")).to eq(30.minutes)
    end

    it "returns 2h для 60d/90d" do
      expect(described_class.ttl_for("60d")).to eq(2.hours)
      expect(described_class.ttl_for("90d")).to eq(2.hours)
    end

    it "returns 24h для 365d" do
      expect(described_class.ttl_for("365d")).to eq(24.hours)
    end

    it "defaults 30m для неизвестного периода" do
      expect(described_class.ttl_for("unknown")).to eq(30.minutes)
    end
  end

  describe ".race_condition_ttl_for" do
    it "returns 30s для short periods" do
      expect(described_class.race_condition_ttl_for("7d")).to eq(30.seconds)
      expect(described_class.race_condition_ttl_for("30d")).to eq(30.seconds)
    end

    it "returns 60s для 365d (expensive compute)" do
      expect(described_class.race_condition_ttl_for("365d")).to eq(60.seconds)
    end
  end
end
