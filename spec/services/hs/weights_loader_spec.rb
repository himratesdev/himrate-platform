# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::WeightsLoader do
  subject(:loader) { described_class.new }

  before do
    SignalConfiguration.where(signal_type: "health_score").delete_all

    # Seed required data
    seed_weights("default", ti: 0.30, stability: 0.20, engagement: 0.20, growth: 0.15, consistency: 0.15)
    seed_weights("just_chatting", ti: 0.30, stability: 0.15, engagement: 0.30, growth: 0.10, consistency: 0.15)
  end

  def seed_weights(category, weights)
    weights.each do |key, value|
      SignalConfiguration.create!(
        signal_type: "health_score",
        category: category,
        param_name: "weight_#{key}",
        param_value: value
      )
    end
  end

  describe "#call" do
    it "loads weights for known category" do
      weights = loader.call("just_chatting")
      expect(weights[:engagement]).to eq(0.30)
      expect(weights[:ti]).to eq(0.30)
    end

    it "falls back to default for unknown category" do
      weights = loader.call("unknown_category")
      expect(weights[:ti]).to eq(0.30)
      expect(weights[:stability]).to eq(0.20)
    end

    it "raises MissingWeights when default is empty too" do
      SignalConfiguration.where(signal_type: "health_score").delete_all
      expect { loader.call("anything") }.to raise_error(described_class::MissingWeights)
    end

    it "memoizes per-instance" do
      expect(SignalConfiguration).to receive(:where).at_most(:twice).and_call_original
      loader.call("just_chatting")
      loader.call("just_chatting")
    end
  end
end
