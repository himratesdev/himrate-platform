# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::AuthRatio do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "default", param_name: "expected_min"
    ) { |c| c.param_value = 0.65 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.15 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "just_chatting", param_name: "expected_min"
    ) { |c| c.param_value = 0.75 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "auth_ratio", category: "esports", param_name: "expected_min"
    ) { |c| c.param_value = 0.58 }
  end

  it "returns value ~0 for normal JC stream (80% auth ratio)" do
    result = signal.calculate(latest_ccv: 1000, latest_chatters: 800, category: "just_chatting")
    expect(result.value).to be_between(0.0, 0.05)
    expect(result.confidence).to eq(1.0)
  end

  it "returns high value for botted stream (20% auth ratio)" do
    result = signal.calculate(latest_ccv: 1000, latest_chatters: 200, category: "default")
    expect(result.value).to be > 0.5
    expect(result.confidence).to eq(1.0)
  end

  it "returns ~0 for esports with 60% auth ratio (within threshold)" do
    result = signal.calculate(latest_ccv: 5000, latest_chatters: 3000, category: "esports")
    expect(result.value).to be_between(0.0, 0.05)
  end

  it "returns nil value for CCV=0" do
    result = signal.calculate(latest_ccv: 0, latest_chatters: 100, category: "default")
    expect(result.value).to be_nil
    expect(result.confidence).to eq(0.0)
  end

  it "returns nil for cold start (CCV < 3)" do
    result = signal.calculate(latest_ccv: 2, latest_chatters: 1, category: "default")
    expect(result.value).to be_nil
  end

  it "returns nil for no chatters data" do
    result = signal.calculate(latest_ccv: 100, latest_chatters: nil, category: "default")
    expect(result.value).to be_nil
  end

  it "returns lower confidence for small CCV" do
    result = signal.calculate(latest_ccv: 15, latest_chatters: 10, category: "default")
    expect(result.confidence).to eq(0.5)
  end

  it "reads weight from DB" do
    expect(signal.weight("default")).to eq(0.15)
  end
end
