# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::InteractionMatrix do
  def make_result(value:, confidence: 1.0, metadata: {})
    TrustIndex::Signals::BaseSignal::Result.new(value: value, confidence: confidence, metadata: metadata)
  end

  # Phase 4 J PR-A CR iter-1 Should Fix (2026-06-03): CPS-touching examples use values
  # in the post-PR signal range [0.0, 0.3] — values 0.8/0.9 the real signal can no longer
  # emit. cond_min in DEFAULT_RULES is now 0.2 (was 0.7).
  it "amplifies known_bot_match when CPS is wide-open (vulnerable channel, value≥0.2)" do
    results = {
      "channel_protection_score" => make_result(value: 0.25), # above new cond_min 0.2
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

  it "does not modify signals below thresholds (Recrent-like CPS=0.15 stays below cond_min)" do
    results = {
      "channel_protection_score" => make_result(value: 0.15), # below post-PR cond_min 0.2
      "known_bot_match" => make_result(value: 0.1),
      "auth_ratio" => make_result(value: 0.0)
    }

    output = described_class.apply(results)
    expect(output[:interactions]).to be_empty
    expect(output[:results]["known_bot_match"].value).to eq(0.1) # unchanged
  end

  it "clamps values to 0-1 after amplification (use post-PR max CPS = 0.3)" do
    results = {
      "channel_protection_score" => make_result(value: 0.3), # post-PR max value
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
