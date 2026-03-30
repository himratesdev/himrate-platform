# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::InteractionMatrix do
  def make_result(value:, confidence: 1.0, metadata: {})
    TrustIndex::Signals::BaseSignal::Result.new(value: value, confidence: confidence, metadata: metadata)
  end

  it "amplifies known_bot_match when CPS is low (vulnerable channel)" do
    results = {
      "channel_protection_score" => make_result(value: 0.8),
      "known_bot_match" => make_result(value: 0.1),
      "auth_ratio" => make_result(value: 0.0)
    }

    output = described_class.apply(results)
    new_known_bot = output[:results]["known_bot_match"].value
    expect(new_known_bot).to be > 0.1 # amplified
    expect(output[:interactions]).not_to be_empty
  end

  it "dampens ccv_step_function when raid explains spike" do
    results = {
      "raid_attribution" => make_result(value: 0.5),
      "ccv_step_function" => make_result(value: 0.6),
      "auth_ratio" => make_result(value: 0.0)
    }

    output = described_class.apply(results)
    new_step = output[:results]["ccv_step_function"].value
    expect(new_step).to be < 0.6 # dampened
  end

  it "does not modify signals below thresholds" do
    results = {
      "channel_protection_score" => make_result(value: 0.3), # below 0.7 threshold
      "known_bot_match" => make_result(value: 0.1),
      "auth_ratio" => make_result(value: 0.0)
    }

    output = described_class.apply(results)
    expect(output[:interactions]).to be_empty
    expect(output[:results]["known_bot_match"].value).to eq(0.1) # unchanged
  end

  it "clamps values to 0-1 after amplification" do
    results = {
      "channel_protection_score" => make_result(value: 0.9),
      "known_bot_match" => make_result(value: 0.9) # × 1.3 = 1.17 → clamped to 1.0
    }

    output = described_class.apply(results)
    expect(output[:results]["known_bot_match"].value).to eq(1.0)
  end

  it "handles nil values gracefully" do
    results = {
      "channel_protection_score" => make_result(value: nil),
      "known_bot_match" => make_result(value: 0.1)
    }

    output = described_class.apply(results)
    expect(output[:interactions]).to be_empty
  end
end
