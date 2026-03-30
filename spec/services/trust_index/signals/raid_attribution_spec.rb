# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::RaidAttribution do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "raid_attribution", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.06 }
  end

  it "returns 0.0 with confidence 1.0 when no raids (clean stream)" do
    result = signal.calculate(raids: [], ccv_series_15min: [])
    expect(result.value).to eq(0.0)
    expect(result.confidence).to eq(1.0)
  end

  it "returns positive value when bot-raid detected" do
    raids = [ { timestamp: 5.minutes.ago, is_bot_raid: true, raid_viewers_count: 500, bot_score: 0.8 } ]
    ccv_series = [
      { ccv: 200, timestamp: 10.minutes.ago },
      { ccv: 700, timestamp: 4.minutes.ago }
    ]
    result = signal.calculate(raids: raids, ccv_series_15min: ccv_series)
    expect(result.value).to be > 0.0
    expect(result.confidence).to eq(0.7) # probabilistic
  end

  it "returns lower value for organic raid" do
    raids = [ { timestamp: 5.minutes.ago, is_bot_raid: false, raid_viewers_count: 500, bot_score: 0.0 } ]
    ccv_series = [
      { ccv: 200, timestamp: 10.minutes.ago },
      { ccv: 700, timestamp: 4.minutes.ago }
    ]
    result = signal.calculate(raids: raids, ccv_series_15min: ccv_series)
    expect(result.value).to be < 0.5
  end

  it "includes raid details in metadata" do
    raids = [ { timestamp: 5.minutes.ago, is_bot_raid: true, raid_viewers_count: 100, bot_score: 0.5 } ]
    result = signal.calculate(raids: raids, ccv_series_15min: [])
    expect(result.metadata[:raids_count]).to eq(1)
  end
end
