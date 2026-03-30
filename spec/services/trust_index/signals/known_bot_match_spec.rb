# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::KnownBotMatch do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "known_bot_match", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.10 }
  end

  it "returns percentage of known bots" do
    scores = [
      { components: { "known_bot_single" => { sources: [ "commanderroot" ] } } },
      { components: { "known_bot_multi" => { sources: %w[commanderroot twitchinsights] } } },
      { components: {} },
      { components: {} },
      { components: {} }
    ]
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to be_within(0.01).of(0.4) # 2/5
    expect(result.metadata[:known_bots]).to eq(2)
  end

  it "returns 0 when no known bots" do
    scores = Array.new(10) { { components: {} } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to eq(0.0)
  end

  it "handles symbol keys in components" do
    scores = [ { components: { known_bot_single: { sources: [ "x" ] } } } ]
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to eq(1.0)
  end

  it "returns nil for empty data" do
    result = signal.calculate(bot_scores: [])
    expect(result.value).to be_nil
  end
end
