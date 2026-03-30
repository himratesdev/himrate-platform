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
