# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::ChatterCcvRatio do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "default", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.10 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.10 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "just_chatting", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.20 }
    SignalConfiguration.find_or_create_by!(
      signal_type: "chatter_ccv_ratio", category: "esports", param_name: "expected_ratio_min"
    ) { |c| c.param_value = 0.02 }
  end

  it "returns ~0 for normal JC stream" do
    result = signal.calculate(unique_chatters_60min: 250, latest_ccv: 1000, category: "just_chatting", stream_duration_min: 60)
    expect(result.value).to be_between(0.0, 0.05)
  end

  it "returns high value for botted stream (very few chatters vs CCV)" do
    result = signal.calculate(unique_chatters_60min: 10, latest_ccv: 1000, category: "default", stream_duration_min: 60)
    expect(result.value).to be > 0.5
  end

  it "returns ~0 for esports with low chatter ratio (1:50 = normal)" do
    result = signal.calculate(unique_chatters_60min: 100, latest_ccv: 5000, category: "esports", stream_duration_min: 60)
    expect(result.value).to eq(0.0)
  end

  it "returns nil when no IRC data" do
    result = signal.calculate(unique_chatters_60min: nil, latest_ccv: 1000, category: "default")
    expect(result.value).to be_nil
  end

  it "returns nil when CCV = 0" do
    result = signal.calculate(unique_chatters_60min: 50, latest_ccv: 0, category: "default")
    expect(result.value).to be_nil
  end
end
