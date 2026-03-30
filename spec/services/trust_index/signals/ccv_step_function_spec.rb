# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::CcvStepFunction do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "ccv_step_function", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.12 }
  end

  def make_series(values)
    values.each_with_index.map { |v, i| { ccv: v, timestamp: i.minutes.ago } }
  end

  it "detects CCV jump 500→2000 (high value)" do
    # Stable at 500, then jump to 2000
    series = make_series([ 500, 510, 490, 505, 495, 500, 510, 2000 ])
    result = signal.calculate(ccv_series_15min: series, recent_raids: [])
    expect(result.value).to be > 0.3
    expect(result.confidence).to be > 0.0
  end

  it "returns 0 for stable CCV" do
    series = make_series([ 500, 510, 490, 505, 495, 500, 510, 505 ])
    result = signal.calculate(ccv_series_15min: series, recent_raids: [])
    expect(result.value).to be < 0.1
  end

  it "dampens value during raid" do
    series = make_series([ 500, 510, 490, 505, 495, 500, 510, 2000 ])
    result_no_raid = signal.calculate(ccv_series_15min: series, recent_raids: [])
    result_raid = signal.calculate(ccv_series_15min: series, recent_raids: [ { timestamp: Time.current } ])

    expect(result_raid.value).to be < result_no_raid.value
    expect(result_raid.metadata[:raid_dampened]).to be true
  end

  it "returns nil for insufficient data (< 5 snapshots)" do
    series = make_series([ 500, 510, 490 ])
    result = signal.calculate(ccv_series_15min: series, recent_raids: [])
    expect(result.value).to be_nil
  end

  it "includes KS test in computation" do
    # Large distribution shift
    series = make_series([ 100, 105, 98, 102, 100, 103, 99, 500, 510, 495, 505, 500 ])
    result = signal.calculate(ccv_series_15min: series, recent_raids: [])
    expect(result.metadata).to have_key(:ks_signal)
  end
end
