# frozen_string_literal: true

require "rails_helper"

RSpec.describe Hs::TrendCalculator do
  let(:channel) { create(:channel) }
  subject(:calc) { described_class.new }

  describe "#call" do
    it "returns nil delta when no history" do
      result = calc.call(channel)
      expect(result[:delta_30d]).to be_nil
      expect(result[:direction]).to be_nil
    end

    it "computes positive delta as 'up'" do
      create_hs(50, 35.days.ago)
      create_hs(60, 1.hour.ago)

      result = calc.call(channel)
      expect(result[:delta_30d]).to eq(10.0)
      expect(result[:direction]).to eq("up")
    end

    it "computes negative delta as 'down'" do
      create_hs(70, 35.days.ago)
      create_hs(60, 1.hour.ago)

      result = calc.call(channel)
      expect(result[:delta_30d]).to eq(-10.0)
      expect(result[:direction]).to eq("down")
    end

    it "returns 'flat' for small delta within ±2" do
      create_hs(60, 35.days.ago)
      create_hs(61, 1.hour.ago)

      result = calc.call(channel)
      expect(result[:direction]).to eq("flat")
    end
  end

  def create_hs(score, calculated_at)
    HealthScore.create!(
      channel_id: channel.id,
      health_score: score,
      confidence_level: "full",
      calculated_at: calculated_at
    )
  end
end
