# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::CcvTierClustering do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "ccv_tier_clustering", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.10 }
  end

  def make_series(values)
    values.each_with_index.map { |v, i| { ccv: v, timestamp: i.minutes.ago } }
  end

  it "detects CCV stable at 1000±5 (bot tier, low CV)" do
    values = Array.new(20) { 1000 + rand(-5..5) }
    result = signal.calculate(ccv_series_30min: make_series(values))
    expect(result.value).to be > 0.5
    expect(result.metadata[:nearest_tier]).to eq(1000)
  end

  it "returns 0 for organic CCV with high variance" do
    values = Array.new(20) { 800 + rand(-200..200) }
    result = signal.calculate(ccv_series_30min: make_series(values))
    expect(result.value).to be < 0.3
  end

  it "returns nil for insufficient data (< 15 snapshots)" do
    result = signal.calculate(ccv_series_30min: make_series([500] * 10))
    expect(result.value).to be_nil
  end

  it "returns nil for mean CCV = 0" do
    result = signal.calculate(ccv_series_30min: make_series([0] * 20))
    expect(result.value).to be_nil
  end

  it "applies adaptive threshold (higher CCV = stricter threshold)" do
    # At CCV 5000, adaptive threshold = 0.05 * sqrt(200/5000) ≈ 0.01
    values_5k = Array.new(20) { 5000 + rand(-50..50) } # CV ≈ 0.006
    result = signal.calculate(ccv_series_30min: make_series(values_5k))
    expect(result.value).to be > 0.0
  end
end
