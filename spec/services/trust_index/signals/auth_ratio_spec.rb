# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::AuthRatio do
  let(:signal) { described_class.new }

  # BUG-251.30: real compute via chatters_present_total / latest_ccv. SignalConfiguration
  # seeds set by `db/migrate/20260529110002_recalibrate_auth_ratio_expected_min_for_chatters_presence`.
  # Tests use explicit config rows to avoid coupling to seed state.
  before do
    {
      "weight_in_ti" => 0.15,
      "expected_min" => 0.030
    }.each do |param_name, param_value|
      SignalConfiguration.find_or_create_by!(
        signal_type: "auth_ratio", category: "default", param_name: param_name
      ) { |c| c.param_value = param_value }
    end

    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "esports", param_name: "expected_min"
    ) { |c| c.param_value = 0.010 }
  end

  describe "real compute (BUG-251.30)" do
    it "returns 0.0 (no alert) when ratio >= expected_min (organic stream)" do
      result = signal.calculate(
        latest_ccv: 1000,
        chatters_present_total: 100,
        category: "default",
        stream_duration_min: 60
      )
      expect(result.value).to eq(0.0)
      expect(result.confidence).to eq(1.0)
      expect(result.metadata[:ratio]).to eq(0.1)
    end

    it "linearly scales to alert when ratio < expected_min" do
      result = signal.calculate(
        latest_ccv: 10000,
        chatters_present_total: 150,
        category: "default",
        stream_duration_min: 60
      )
      expect(result.value).to eq(0.5)
      expect(result.confidence).to eq(1.0)
    end

    it "returns 1.0 (max alert) when chatters_present_total = 0 (all viewers anonymous)" do
      result = signal.calculate(
        latest_ccv: 5000,
        chatters_present_total: 0,
        category: "default",
        stream_duration_min: 60
      )
      expect(result.value).to eq(1.0)
      expect(result.confidence).to eq(1.0)
    end

    it "uses category-adjusted threshold (esports lower expected_min)" do
      result = signal.calculate(
        latest_ccv: 1450,
        chatters_present_total: 106,
        category: "esports",
        stream_duration_min: 154
      )
      expect(result.value).to eq(0.0)
      expect(result.metadata[:expected_min]).to eq(0.01)
    end

    it "reads expected_min from SignalConfiguration via category fallback to default" do
      result = signal.calculate(
        latest_ccv: 1000,
        chatters_present_total: 25,
        category: "unknown_category",
        stream_duration_min: 60
      )
      expect(result.value).to be_within(0.001).of(0.166)
    end
  end

  describe "confidence tiers" do
    it "confidence 1.0 when stream >= 30 min and CCV >= 50" do
      result = signal.calculate(
        latest_ccv: 100, chatters_present_total: 10,
        category: "default", stream_duration_min: 30
      )
      expect(result.confidence).to eq(1.0)
    end

    it "confidence 0.5 when stream 10-30 min" do
      result = signal.calculate(
        latest_ccv: 100, chatters_present_total: 10,
        category: "default", stream_duration_min: 15
      )
      expect(result.confidence).to eq(0.5)
    end

    it "confidence 0.2 when stream < 10 min" do
      result = signal.calculate(
        latest_ccv: 100, chatters_present_total: 10,
        category: "default", stream_duration_min: 5
      )
      expect(result.confidence).to eq(0.2)
    end
  end

  describe "insufficient cases" do
    it "reports no_ccv when CCV absent" do
      result = signal.calculate(
        latest_ccv: 0, chatters_present_total: 50,
        category: "default", stream_duration_min: 60
      )
      expect(result.value).to be_nil
      expect(result.confidence).to eq(0.0)
      expect(result.metadata[:reason]).to eq("no_ccv")
    end

    it "reports no_ccv when CCV nil" do
      result = signal.calculate(
        latest_ccv: nil, chatters_present_total: 50,
        category: "default", stream_duration_min: 60
      )
      expect(result.value).to be_nil
      expect(result.metadata[:reason]).to eq("no_ccv")
    end

    it "reports no_chatters_present_data when chatters_present_total nil" do
      result = signal.calculate(
        latest_ccv: 1000, chatters_present_total: nil,
        category: "default", stream_duration_min: 60
      )
      expect(result.value).to be_nil
      expect(result.confidence).to eq(0.0)
      expect(result.metadata[:reason]).to eq("no_chatters_present_data")
    end
  end

  describe "weight" do
    it "reads weight from SignalConfiguration" do
      expect(signal.weight("default")).to eq(0.15)
    end
  end
end
