# frozen_string_literal: true

require "rails_helper"

RSpec.describe SignalConfiguration do
  before { SignalConfiguration.delete_all }

  describe "validations" do
    it "validates uniqueness of signal_type + category + param_name" do
      SignalConfiguration.create!(signal_type: "auth_ratio", category: "default", param_name: "weight", param_value: 0.15)
      dup = SignalConfiguration.new(signal_type: "auth_ratio", category: "default", param_name: "weight", param_value: 0.20)
      expect(dup).not_to be_valid
    end

    it "requires all fields" do
      record = SignalConfiguration.new
      expect(record).not_to be_valid
      expect(record.errors.attribute_names).to include(:signal_type, :category, :param_name, :param_value)
    end
  end

  describe ".value_for" do
    before do
      SignalConfiguration.create!(signal_type: "auth_ratio", category: "just_chatting", param_name: "expected_min", param_value: 0.75)
      SignalConfiguration.create!(signal_type: "auth_ratio", category: "default", param_name: "expected_min", param_value: 0.65)
    end

    it "returns exact match for category" do
      expect(described_class.value_for("auth_ratio", "just_chatting", "expected_min")).to eq(0.75)
    end

    it "falls back to default category" do
      expect(described_class.value_for("auth_ratio", "unknown_category", "expected_min")).to eq(0.65)
    end

    it "raises ConfigurationMissing when not found" do
      expect { described_class.value_for("nonexistent", "default", "x") }
        .to raise_error(SignalConfiguration::ConfigurationMissing)
    end
  end

  describe ".value_for CR W-3 request-scoped cache" do
    before do
      SignalConfiguration.create!(signal_type: "cache_test", category: "c", param_name: "x", param_value: 42)
    end

    it "caches subsequent lookups в Current (admin DB update не видна до end of request/job)" do
      expect(described_class.value_for("cache_test", "c", "x")).to eq(42)

      SignalConfiguration.where(signal_type: "cache_test", category: "c", param_name: "x").update_all(param_value: 99)

      expect(described_class.value_for("cache_test", "c", "x")).to eq(42)
    end

    it "refreshes cache after Current.reset (next request/job boundary)" do
      described_class.value_for("cache_test", "c", "x")
      SignalConfiguration.where(signal_type: "cache_test", category: "c", param_name: "x").update_all(param_value: 99)

      ActiveSupport::CurrentAttributes.clear_all

      expect(described_class.value_for("cache_test", "c", "x")).to eq(99)
    end

    it "cache per-key (разные params изолированы)" do
      SignalConfiguration.create!(signal_type: "cache_test", category: "c", param_name: "y", param_value: 100)

      expect(described_class.value_for("cache_test", "c", "x")).to eq(42)
      expect(described_class.value_for("cache_test", "c", "y")).to eq(100)
    end

    it "missing key raises каждый раз (не caches nil)" do
      expect { described_class.value_for("nil_key", "c", "nope") }.to raise_error(SignalConfiguration::ConfigurationMissing)
      expect { described_class.value_for("nil_key", "c", "nope") }.to raise_error(SignalConfiguration::ConfigurationMissing)
    end
  end

  describe ".params_for" do
    before do
      SignalConfiguration.create!(signal_type: "auth_ratio", category: "default", param_name: "expected_min", param_value: 0.65)
      SignalConfiguration.create!(signal_type: "auth_ratio", category: "default", param_name: "expected_max", param_value: 0.80)
    end

    it "returns all params as hash" do
      params = described_class.params_for("auth_ratio", "default")
      expect(params).to eq("expected_min" => 0.65, "expected_max" => 0.80)
    end

    it "raises when no configs found" do
      expect { described_class.params_for("nonexistent", "default") }
        .to raise_error(SignalConfiguration::ConfigurationMissing)
    end
  end
end
