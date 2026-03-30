# frozen_string_literal: true

require "rails_helper"

RSpec.describe TrustIndex::Signals::ChatBehavior do
  let(:signal) { described_class.new }

  before do
    SignalConfiguration.find_or_create_by!(
      signal_type: "chat_behavior", category: "default", param_name: "weight_in_ti"
    ) { |c| c.param_value = 0.12 }
  end

  it "returns low value for mostly human chatters" do
    scores = Array.new(50) { { bot_score: 0.1, confidence: 0.8, classification: "human" } }
    result = signal.calculate(bot_scores: scores)
    expect(result.value).to be < 0.2
  end

  it "returns high value when many confirmed bots" do
    humans = Array.new(30) { { bot_score: 0.1, confidence: 0.8, classification: "human" } }
    bots = Array.new(20) { { bot_score: 0.95, confidence: 0.9, classification: "confirmed_bot" } }
    result = signal.calculate(bot_scores: humans + bots)
    expect(result.value).to be > 0.3
  end

  it "uses weighted mean (not simple ratio)" do
    # High confidence bots should weight more than low confidence
    high_conf_bots = Array.new(5) { { bot_score: 0.9, confidence: 1.0, classification: "probable_bot" } }
    low_conf_humans = Array.new(45) { { bot_score: 0.1, confidence: 0.3, classification: "human" } }
    result = signal.calculate(bot_scores: high_conf_bots + low_conf_humans)
    expect(result.metadata[:weighted_mean]).to be > 0.1
  end

  it "returns nil for empty bot scores" do
    result = signal.calculate(bot_scores: [])
    expect(result.value).to be_nil
  end

  it "returns full confidence for 50+ chatters" do
    scores = Array.new(60) { { bot_score: 0.1, confidence: 0.8, classification: "human" } }
    result = signal.calculate(bot_scores: scores)
    expect(result.confidence).to be >= 0.7
  end
end
